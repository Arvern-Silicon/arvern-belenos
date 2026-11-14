#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    cdc_check.py (belenos)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Structural clock-domain-crossing check of belenos (Yosys + Python standard
# library; no commercial CDC tool).
#
#   ./cdc_check.py                  the CDC configurations (CDC_CONFIGS)
#   ./cdc_check.py tang_hdmi ...    the configurations named (labels of
#                                   sim/rtl_sim/bin/rtl_configs.py)
#   -rtl <dir>                      another RTL directory (self-test copies)
#   -waivers <file>                 another waiver file (default waivers.txt)
#   -v                              list the accepted crossings too
#   -selftest                       seed two faults in a temporary RTL copy
#                                   (logic in front of a synchroniser, a
#                                   synchroniser bypassed) and check that
#                                   both are reported (exit 0 if they are)
#
# For each configuration Yosys elaborates belenos with its parameters
# (read_verilog, hierarchy, proc, flatten, memory) and writes the netlist as
# JSON. The script then:
#   1. gives every flop the domain of the clock port its clock pin traces
#      back to (hclk_i, dpi_pclk_i); input ports have a declared domain
#      (PORT_DOMAIN: the bus side is hclk, the line-buffer read data and the
#      pixel reset are pclk, the panel and audio pins are async);
#   2. follows every flop's data, enable and synchronous-reset pins back
#      through combinational logic to flops and input ports, and reports each
#      source of another domain:
#        - into the first stage (meta_q) of an arv_synchronizer of the
#          destination domain, directly from a flop or a port: accepted
#          (listed with -v); through logic: COMB_SYNC error;
#        - anything else: a CROSSING error unless a waiver (the documented
#          quasi-static and toggle-protected buses of blns_dpi_cdc.v's header
#          and doc/integration_guide.md "Separate pixel clock") covers it;
#      an asynchronous port reaching anything but a synchroniser first stage
#      is a CROSSING too;
#   3. MULTIBIT: two or more bits of one source register synchronised bit by
#      bit (in one synchroniser or several);
#   4. RECONV: a destination flop whose combinational cone combines two or
#      more separately synchronised bits;
#   5. OUTPUT: an output port driven from a domain other than its own;
#   6. RESET: a flop whose asynchronous reset is not its own domain's
#      (hresetn_i for hclk_i, dpi_presetn_i for dpi_pclk_i).
# Every bundle of more than one bit is listed in the report with the source
# of each bit. Items 2-6 fail the check unless a waiver of waivers.txt
# covers them; a waiver no configuration uses is STALE (an error when every
# CDC configuration is run, so the file stays exact).
#
# Reports: lint/cdc/results/<config>/cdc_report.txt (and the netlist).
# Exit status 0 when every configuration is clean.
#----------------------------------------------------------------------------

import fnmatch
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

CDC_DIR  = os.path.dirname(os.path.abspath(__file__))
REPO_DIR = os.path.normpath(os.path.join(CDC_DIR, '..', '..'))
BIN_DIR  = os.path.join(REPO_DIR, 'sim', 'rtl_sim', 'bin')
RES_DIR  = os.path.join(CDC_DIR, 'results')

sys.path.insert(0, BIN_DIR)
import rtl_configs  # noqa: E402
import flatten_filelist  # noqa: E402

# The configurations with a crossing: a separate pixel clock (DPI, HDMI,
# HDMI audio and its I2S inputs, the deployed Tang builds, the synchronous
# reset) and the DBI asynchronous inputs (TE, 8080 read data)
CDC_CONFIGS = ['dif4_pclk', 'dif5_pclk', 'dif5_audio', 'tang_hdmi', 'tang_panel', 'sync_rst_dif5',
               'sync_rst_audio', 'dif3']

CLOCKS = {'hclk_i': 'hclk', 'dpi_pclk_i': 'pclk'}
# Input ports that are not on hclk_i (every other input is)
PORT_DOMAIN = {
    'dpi_presetn_i':  'pclk',              # pixel-domain reset, released on dpi_pclk_i
    'dpi_lb_rdata_i': 'pclk',              # line-buffer read port (dual-clock RAM, read side)
    'panel_detect_i': 'async', 'ddc_scl_i': 'async', 'ddc_sda_i': 'async',
    'i2s_bclk_i': 'async', 'i2s_lrck_i': 'async', 'i2s_sd_i': 'async',
    'lcd_te_i': 'async', 'lcd_d_i': 'async', 'spi_miso_i': 'async',
}
# Output ports that are not on hclk_i
OUT_DOMAIN = {p: 'pclk' for p in ('dpi_de_o', 'dpi_hs_o', 'dpi_vs_o', 'dpi_rgb_o', 'dpi_clk_d0_o',
                                  'dpi_clk_d1_o', 'tmds_o', 'dpi_lb_raddr_o')}
RESETS = ('hresetn_i', 'dpi_presetn_i')

FF_TYPES = {'$dff', '$dffe', '$adff', '$adffe', '$sdff', '$sdffe', '$sdffce', '$dffsr', '$dffsre',
            '$aldff', '$aldffe', '$dlatch', '$adlatch', '$dlatchsr'}
FF_DATA  = ('D', 'EN', 'SRST', 'AD')          # sampled with the clock (ARST/SET/CLR: asynchronous)
SYNC_MOD = 'arv_synchronizer'


#=============================================================================
# ELABORATION
#=============================================================================
def elaborate(label, params, rtl_dir, out_dir):
    os.makedirs(out_dir, exist_ok=True)
    flist = os.path.join(out_dir, 'files.f')
    lines = flatten_filelist.process_filelist(os.path.join(rtl_dir, 'filelist.f'))
    files = [l.strip() for l in lines if l.strip() and not l.strip().startswith('//')]
    with open(flist, 'w') as f:
        f.write('\n'.join(files) + '\n')
    chp = ' '.join('-chparam %s %s' % (k, v) for k, v in sorted(params.items()))
    ys = os.path.join(out_dir, 'elab.ys')
    with open(ys, 'w') as f:
        f.write('read_verilog -DSYNTHESIS %s\n' % ' '.join(files))
        f.write('hierarchy -check -top %s %s\n' % (rtl_configs.TOP_MODULE, chp))
        f.write('proc\nflatten\nmemory\nopt_clean\nwrite_json netlist.json\n')
    p = subprocess.run(['yosys', '-q', '-l', 'yosys.log', '-s', 'elab.ys'], cwd=out_dir,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=900)
    if p.returncode != 0:
        raise RuntimeError('%s: Yosys failed (see %s)\n%s' % (label, os.path.join(out_dir, 'yosys.log'),
                                                            p.stdout[-2000:]))
    with open(os.path.join(out_dir, 'netlist.json')) as f:
        return json.load(f)['modules'][rtl_configs.TOP_MODULE]


#=============================================================================
# NETLIST
#=============================================================================
def inst_path(cell_name):
    """Instance path of a flattened cell: '$flatten\\a.\\b.$procdff$1' -> 'a.b'."""
    n = cell_name
    if n.startswith('$flatten'):
        n = n[len('$flatten'):]
    n = n.replace('\\', '')
    i = n.rfind('.$')
    return n[:i] if i >= 0 else ''


class Netlist:
    def __init__(self, mod):
        self.mod = mod
        self.ports = mod['ports']
        self.port_bit = {}                    # bit -> (port, index)
        for pn, p in self.ports.items():
            for i, b in enumerate(p['bits']):
                if p['direction'] == 'input' and isinstance(b, int):
                    self.port_bit[b] = (pn, i)
        self.scope = {}                       # instance path -> module name
        self.drv = {}                         # bit -> (cell, port, index)
        self.cells = mod['cells']
        for cn, c in self.cells.items():
            if c['type'] == '$scopeinfo':
                self.scope[cn.replace('\\', '')] = c['attributes'].get('module_hdlname', '')
                continue
            for pn, d in c.get('port_directions', {}).items():
                if d == 'output':
                    for i, b in enumerate(c['connections'][pn]):
                        if isinstance(b, int):
                            self.drv[b] = (cn, pn, i)
        # Names: the best public net name of each bit
        self.bit_name = {}
        self.bit_names = {}                   # bit -> every public name
        for nn, n in mod['netnames'].items():
            if n.get('hide_name'):
                continue
            for i, b in enumerate(n['bits']):
                if isinstance(b, int):
                    nm = nn if len(n['bits']) == 1 else '%s[%d]' % (nn, i)
                    self.bit_names.setdefault(b, []).append(nm)
                    old = self.bit_name.get(b)
                    if old is None or nm.count('.') > old.count('.'):
                        self.bit_name[b] = nm
        self.ffs = {cn: c for cn, c in self.cells.items() if c['type'] in FF_TYPES}
        self.ff_q = {}                        # Q bit -> (cell, index)
        for cn, c in self.ffs.items():
            for i, b in enumerate(c['connections']['Q']):
                self.ff_q[b] = (cn, i)
        self.domain = {cn: self.clock_domain(cn) for cn in self.ffs}

    def module_of(self, cn):
        return self.scope.get(inst_path(cn), '')

    def reg_name(self, cn):
        """A flop's register: the arv_ipdff instance, else its Q net."""
        path = inst_path(cn)
        if self.module_of(cn).startswith('arv_ipdff'):
            return path
        q = self.ffs[cn]['connections']['Q'][0]
        nm = self.bit_name.get(q, cn)
        return re.sub(r'\[\d+\]$', '', nm)

    def _q_named(self, cn, wire):
        q = self.ffs[cn]['connections']['Q'][0]
        return any(n.startswith(inst_path(cn) + '.' + wire) for n in self.bit_names.get(q, []))

    def is_meta(self, cn):
        """First stage of an arv_synchronizer."""
        return self.module_of(cn) == SYNC_MOD and self._q_named(cn, 'meta_q')

    def is_sync_out(self, cn):
        """Second stage (the output) of an arv_synchronizer."""
        return self.module_of(cn) == SYNC_MOD and self._q_named(cn, 'sync_q')

    def clock_domain(self, cn):
        c = self.ffs[cn]
        pin = 'CLK' if 'CLK' in c['connections'] else 'EN'
        seen = set()
        todo = list(c['connections'][pin])
        while todo:
            b = todo.pop()
            if not isinstance(b, int) or b in seen:
                continue
            seen.add(b)
            if b in self.port_bit:
                pn = self.port_bit[b][0]
                if pn in CLOCKS:
                    return CLOCKS[pn]
                continue
            d = self.drv.get(b)
            if d and d[0] not in self.ffs:
                cc = self.cells[d[0]]
                for pn, dd in cc['port_directions'].items():
                    if dd == 'input':
                        todo += cc['connections'][pn]
        return 'unknown'

    def cone(self, bit, memo):
        """Sources of a bit through combinational logic:
        {(kind, id): through_logic}, kind 'ff' (cell, index) or 'port' (port, index)."""
        if not isinstance(bit, int):
            return {}
        if bit in memo:
            return memo[bit]
        memo[bit] = {}
        if bit in self.ff_q:
            r = {('ff', self.ff_q[bit]): False}
        elif bit in self.port_bit:
            r = {('port', self.port_bit[bit]): False}
        elif bit in self.drv:
            cn = self.drv[bit][0]
            c = self.cells[cn]
            r = {}
            for pn, d in c['port_directions'].items():
                if d != 'input':
                    continue
                for b in c['connections'][pn]:
                    for k in self.cone(b, memo):
                        r[k] = True
        else:
            r = {}
        memo[bit] = r
        return r


#=============================================================================
# WAIVERS
#=============================================================================
KINDS = ('CROSSING', 'COMB_SYNC', 'MULTIBIT', 'RECONV', 'OUTPUT', 'RESET')


def load_waivers(path):
    """Lines: KIND  source-pattern  destination-pattern  | reason (doc ref).
    Patterns are shell globs on the names the report prints."""
    out = []
    with open(path) as f:
        for n, line in enumerate(f, 1):
            line = line.rstrip('\n')
            if not line.strip() or line.lstrip().startswith('#'):
                continue
            body, sep, reason = line.partition('|')
            parts = body.split()
            if not sep or not reason.strip() or len(parts) != 3 or parts[0] not in KINDS:
                raise SystemExit('%s:%d: expected "KIND src dst | reason"' % (path, n))
            out.append({'kind': parts[0], 'src': parts[1], 'dst': parts[2], 'reason': reason.strip(),
                        'line': n, 'used': set()})
    return out


def waived(waivers, kind, src, dst, label):
    for w in waivers:
        if w['kind'] == kind and fnmatch.fnmatchcase(src, w['src']) and fnmatch.fnmatchcase(dst, w['dst']):
            w['used'].add(label)
            return w
    return None


#=============================================================================
# CHECK
#=============================================================================
def strip_bit(n):
    return re.sub(r'\[\d+\]$', '', n)


def check(label, net, waivers, verbose):
    rep, errs, oks = [], [], []
    memo = {}

    def src_name(src):
        kind, ident = src
        if kind == 'port':
            return ident[0]
        return net.reg_name(ident[0])

    def src_domain(src):
        kind, ident = src
        if kind == 'port':
            return PORT_DOMAIN.get(ident[0], 'hclk')
        return net.domain[ident[0]]

    def item(kind, src, dst, detail):
        w = waived(waivers, kind, src, dst, label)
        line = '%-9s %s -> %s  %s' % (kind, src, dst, detail)
        if w:
            oks.append('WAIVED    %s  [waivers.txt:%d]' % (line[10:], w['line']))
        else:
            errs.append(line)

    unknown = sorted(set(net.reg_name(cn) for cn, d in net.domain.items() if d == 'unknown'))
    for r in unknown:
        errs.append('CLOCK     %s: clock pin traces to no clock port' % r)

    # Asynchronous resets: each flop is cleared by its own domain's reset
    rst_dom = {'hresetn_i': 'hclk', 'dpi_presetn_i': 'pclk'}
    bad_rst = set()
    for cn, c in sorted(net.ffs.items()):
        for pin in ('ARST', 'SET', 'CLR', 'ALOAD'):
            for b in c['connections'].get(pin, []):
                for src, logic in net.cone(b, memo).items():
                    if src[0] == 'port' and rst_dom.get(src[1][0]) == net.domain[cn]:
                        continue
                    bad_rst.add((src_name(src), net.reg_name(cn), net.domain[cn]))
    for s, d, dom in sorted(bad_rst):
        item('RESET', s, d, '(asynchronous reset of a %s flop)' % dom)

    crossings, syncs = {}, {}            # aggregated per (src reg, dst reg)
    sync_src = {}                        # meta cell -> {bit: (src kind, ident)}
    for cn, c in sorted(net.ffs.items()):
        ddom = net.domain[cn]
        dname = net.reg_name(cn)
        meta = net.is_meta(cn)
        for pin in FF_DATA:
            for qi, b in enumerate(c['connections'].get(pin, [])):
                if meta and pin == 'D':
                    b = skip_reset_mux(net, b)
                for src, logic in net.cone(b, memo).items():
                    sdom = src_domain(src)
                    if sdom == ddom:
                        continue
                    if src[0] == 'port' and src[1][0] in RESETS and meta and pin == 'D':
                        continue
                    sname = src_name(src)
                    if meta and pin == 'D':
                        if logic:
                            item('COMB_SYNC', sname, dname, '(%s -> %s, logic before the first stage)' % (sdom, ddom))
                        else:
                            syncs.setdefault((sname, dname), set()).add('%s->%s' % (sdom, ddom))
                            sync_src.setdefault(cn, {})[qi] = src
                        continue
                    crossings.setdefault((sname, dname), set()).add('%s->%s' % (sdom, ddom))
    for (s, d), doms in sorted(crossings.items()):
        item('CROSSING', s, d, '(%s)' % ', '.join(sorted(doms)))
    for (s, d), doms in sorted(syncs.items()):
        oks.append('SYNC      %s -> %s  (%s)' % (s, d, ', '.join(sorted(doms))))

    # Bundles and multi-bit values synchronised bit by bit
    reg_bits = {}                        # source register -> [(sync inst, bit)]
    rep.append('Synchroniser bundles (W > 1): bit <- source')
    for cn in sorted(sync_src):
        bits = sync_src[cn]
        inst = inst_path(cn)
        for qi, src in sorted(bits.items()):
            reg_bits.setdefault(src_name(src), []).append((inst, qi))
        if len(net.ffs[cn]['connections']['Q']) > 1:
            rep.append('  %s (W=%d)' % (inst, len(net.ffs[cn]['connections']['Q'])))
            for qi, src in sorted(bits.items()):
                nm = net.bit_name.get(src[1][0], '') if src[0] == 'port' else ''
                rep.append('    [%d] <- %s%s' % (qi, src_name(src),
                                                 '' if src[0] == 'port' else '[%d]' % src[1][1]))
    for reg, uses in sorted(reg_bits.items()):
        if len(uses) > 1:
            item('MULTIBIT', reg, ','.join(sorted(set(u[0] for u in uses))),
                 '(%d bits of one register: %s)' % (len(uses), ' '.join('%s[%d]' % u for u in uses)))

    # Reconvergence: a flop combining separately synchronised bits
    sync_out = {}
    for cn in net.ffs:
        if net.is_sync_out(cn):
            for i, b in enumerate(net.ffs[cn]['connections']['Q']):
                sync_out[(cn, i)] = '%s.sync_q[%d]' % (inst_path(cn), i)
    reconv = {}
    dests = [(net.reg_name(cn), [b for pin in FF_DATA for b in c['connections'].get(pin, [])])
             for cn, c in sorted(net.ffs.items()) if net.module_of(cn) != SYNC_MOD]
    dests += [(pn, p['bits']) for pn, p in sorted(net.ports.items()) if p['direction'] == 'output']
    for dname, bits in dests:
        used = set()
        for b in bits:
            for src in net.cone(b, memo):
                if src[0] == 'ff' and src[1] in sync_out:
                    used.add(sync_out[src[1]])
        if len(used) > 1:
            reconv.setdefault(','.join(sorted(used)), set()).add(dname)
    for sigs, dsts in sorted(reconv.items()):
        for d in sorted(dsts):
            item('RECONV', sigs, d, '')

    # Outputs
    for pn, p in sorted(net.ports.items()):
        if p['direction'] != 'output':
            continue
        odom = OUT_DOMAIN.get(pn, 'hclk')
        doms = set()
        for b in p['bits']:
            for src in net.cone(b, memo):
                sd = src_domain(src)
                if sd != odom:
                    doms.add((src_name(src), sd))
        for s, sd in sorted(doms):
            item('OUTPUT', s, pn, '(%s source, %s port)' % (sd, odom))

    return rep, errs, oks


def skip_reset_mux(net, b):
    """The synchronous-reset synchroniser loads its reset value through a mux
    on the first stage, selected by the destination reset: look through it."""
    d = net.drv.get(b)
    if not d or net.cells[d[0]]['type'] != '$mux':
        return b
    c = net.cells[d[0]]
    s = c['connections']['S'][0]
    if s not in net.port_bit or net.port_bit[s][0] not in RESETS:
        return b
    a, bb = c['connections']['A'][d[2]], c['connections']['B'][d[2]]
    if isinstance(a, str):
        return bb
    if isinstance(bb, str):
        return a
    return b


#=============================================================================
# MAIN
#=============================================================================
SELFTEST = [
    ('blns_dpi_cdc.v', '.async_i ( {en_i, req_i, sz_req_i, fill_i}           ),',
                       '.async_i ( {en_i & ~req_i, req_i, sz_req_i, fill_i}  ),', 'COMB_SYNC', 'u_req'),
    ('blns_dpi.v',     '    .en_i             ( en_p             ),',
                       '    .en_i             ( pix_en           ),', 'CROSSING', 'u_pix_en'),
]


def selftest():
    """Seed the SELFTEST faults into a copy of the RTL (arvern-ips linked
    beside it, as filelist.f expects) and check that both are reported."""
    tmp = tempfile.mkdtemp(prefix='blns_cdc_self_')
    try:
        rtl = os.path.join(tmp, 'arvern-belenos', 'rtl', 'verilog')
        shutil.copytree(os.path.join(REPO_DIR, 'rtl', 'verilog'), rtl)
        os.symlink(os.path.normpath(os.path.join(REPO_DIR, '..', 'arvern-ips')), os.path.join(tmp, 'arvern-ips'))
        for fname, old, new, _, _ in SELFTEST:
            path = os.path.join(rtl, fname)
            with open(path) as f:
                text = f.read()
            if text.count(old) != 1:
                print('selftest: the seed no longer matches %s' % fname)
                return 1
            with open(path, 'w') as f:
                f.write(text.replace(old, new))
        label = 'dif4_pclk'
        net = Netlist(elaborate(label, dict(rtl_configs.CONFIGS)[label], rtl, os.path.join(tmp, 'out')))
        _, errs, _ = check(label, net, load_waivers(os.path.join(CDC_DIR, 'waivers.txt')), False)
        bad = 0
        for _, _, _, kind, src in SELFTEST:
            hit = [e for e in errs if e.startswith(kind) and src in e.split(' -> ')[0]]
            print('%s  seeded %s from %s: %d error(s)' % ('OK  ' if hit else 'MISS', kind, src, len(hit)))
            bad += not hit
        print('cdc_check selftest: %s' % ('PASS' if not bad else 'FAIL'))
        return 1 if bad else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def main(argv):
    rtl_dir = os.path.join(REPO_DIR, 'rtl', 'verilog')
    wfile = os.path.join(CDC_DIR, 'waivers.txt')
    verbose = False
    labels = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == '-rtl':
            i += 1
            rtl_dir = os.path.abspath(argv[i])
        elif a == '-waivers':
            i += 1
            wfile = os.path.abspath(argv[i])
        elif a == '-v':
            verbose = True
        elif a == '-selftest':
            return selftest()
        elif a in ('-h', '-help', '--help'):
            print(open(__file__).read().split('#---')[2].replace('\n# ', '\n').replace('\n#', '\n'))
            return 0
        else:
            labels.append(a)
        i += 1
    full = not labels
    labels = labels or CDC_CONFIGS
    cfgs = dict(rtl_configs.CONFIGS)
    waivers = load_waivers(wfile)
    bad = 0
    summary = []
    for label in labels:
        if label not in cfgs:
            raise SystemExit('cdc_check: unknown configuration %s' % label)
        out_dir = os.path.join(RES_DIR, label)
        net = Netlist(elaborate(label, cfgs[label], rtl_dir, out_dir))
        rep, errs, oks = check(label, net, waivers, verbose)
        doms = {}
        for d in net.domain.values():
            doms[d] = doms.get(d, 0) + 1
        nsync = sum(1 for o in oks if o.startswith('SYNC'))
        nwv = sum(1 for o in oks if o.startswith('WAIVED'))
        head = ['belenos CDC check: %s %s' % (label, ' '.join('%s=%s' % kv for kv in sorted(cfgs[label].items()))),
                'flops per domain: %s' % ', '.join('%s %d' % kv for kv in sorted(doms.items())),
                '%d synchronised crossings, %d waived, %d errors' % (nsync, nwv, len(errs)), '']
        body = head + ['ERRORS'] + ['  ' + e for e in errs] + [''] + rep + [''] + \
            ['ACCEPTED'] + ['  ' + o for o in oks]
        with open(os.path.join(out_dir, 'cdc_report.txt'), 'w') as f:
            f.write('\n'.join(body) + '\n')
        status = 'PASS' if not errs else 'FAIL'
        bad += bool(errs)
        summary.append('%-4s %-16s flops %s; %d synchronised, %d waived, %d errors' % (
            status, label, '/'.join('%s %d' % kv for kv in sorted(doms.items())), nsync, nwv, len(errs)))
        print(summary[-1], flush=True)
        for e in errs:
            print('       ' + e)
        if verbose:
            for o in oks:
                print('       ' + o)
    stale = [w for w in waivers if not w['used']]
    for w in stale:
        print('%s waivers.txt:%d %s %s %s (no configuration run uses it)' % (
            'STALE' if full else 'unused', w['line'], w['kind'], w['src'], w['dst']))
    if full and stale:
        bad += 1
    print('cdc_check: %d configurations, %s' % (len(labels), 'clean' if not bad else 'FAILED'))
    print('reports: %s/<config>/cdc_report.txt' % os.path.relpath(RES_DIR))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
