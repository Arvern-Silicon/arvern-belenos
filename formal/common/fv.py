#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    fv.py (belenos formal)
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Driver of the formal proofs: Yosys (read, elaborate, flatten, then
# async2sync for one clock or clk2fflogic for several) writes an SMT2 model,
# yosys-smtbmc (z3) checks it. Python standard library only; no SymbiYosys.
#
# A proof is a directory formal/<name>/ with a proof.json:
#   top        harness module
#   files      sources: "rtl:<f>" (rtl/verilog), "ips:<f>" (arv_primitives),
#              "common:<f>" (formal/common), or a file of the proof directory
#   clocking   "single" (async2sync) or "multi" (clk2fflogic: every clock a
#              free input, sampled on the solver's global step)
#   probes     {harness wire: flattened DUT wire}: the harness declares the
#              wire undriven, the driver connects it after flattening
#              (Yosys has no hierarchical references; bind is not supported)
#   tasks      {name: {params, depth, induction, cover, timeout, probes,
#              comb_free}}: comb_free lists harness wires (DUT outputs)
#              whose combinational input cone, cut at every flop, must hold
#              no harness input: outputs that come from flops only (checked
#              by Yosys on the elaborated design, a step of its own)
#   mutations  [{name, task, file, from, to, expect: [assert labels]}]:
#              each edit is applied to a temporary copy of the RTL; the
#              task's bounded check must then fail on one of the labels
#
# A task passes when the bounded check (BMC, depth steps, from reset) finds
# no failing assertion, the induction step at the same depth proves (when
# "induction" is set), and every cover statement is reached (when "cover"
# is set: no assumption hides the behaviour the assertions are about).
#----------------------------------------------------------------------------

import json
import os
import re
import shutil
import subprocess
import tempfile
import time

FORMAL_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_DIR   = os.path.dirname(FORMAL_DIR)
RTL_DIR    = os.path.join(REPO_DIR, 'rtl', 'verilog')
IPS_DIR    = os.path.normpath(os.path.join(REPO_DIR, '..', 'arvern-ips', 'arv_primitives', 'rtl', 'verilog'))
COMMON_DIR = os.path.join(FORMAL_DIR, 'common')


def find_proofs():
    """Every formal/<name>/proof.json, sorted by name."""
    out = []
    for name in sorted(os.listdir(FORMAL_DIR)):
        if os.path.isfile(os.path.join(FORMAL_DIR, name, 'proof.json')):
            out.append(name)
    return out


def load_proof(name):
    with open(os.path.join(FORMAL_DIR, name, 'proof.json')) as f:
        return json.load(f)


def resolve(spec, proof_dir, rtl_dir):
    if spec.startswith('rtl:'):
        return os.path.join(rtl_dir, spec[4:])
    if spec.startswith('ips:'):
        return os.path.join(IPS_DIR, spec[4:])
    if spec.startswith('common:'):
        return os.path.join(COMMON_DIR, spec[7:])
    return os.path.join(proof_dir, spec)


def yosys_script(proof, task, proof_dir, rtl_dir, smt2):
    files = [resolve(s, proof_dir, rtl_dir) for s in proof['files']]
    defines = ['-DFORMAL'] + ['-D' + d for d in proof.get('defines', []) + task.get('defines', [])]
    lines = ['read_verilog -formal -sv %s %s' % (' '.join(defines), ' '.join(files))]
    chp = ' '.join('-chparam %s %s' % (k, v) for k, v in sorted(task.get('params', {}).items()))
    lines.append('hierarchy -check -top %s %s' % (task.get('top', proof['top']), chp))
    lines.append('proc')
    lines.append('flatten')
    # Probes: connected at once (before any optimisation can drop the
    # target), those of a memory's words ("probes_mem") once it is mapped
    probes = dict(proof.get('probes', {}))
    probes.update(task.get('probes', {}))
    mem = {k: v for k, v in probes.items() if k in task.get('probes_mem', [])}
    for wire, target in sorted(probes.items()):
        if wire not in mem:
            lines.append('connect -set %s %s' % (wire, target))
    lines.append('memory')                       # memories as flops (z3 is slow on arrays)
    for wire, target in sorted(mem.items()):
        lines.append('connect -set %s %s' % (wire, target))
    lines.append('opt_clean')
    if proof.get('clocking', 'single') == 'multi':
        lines.append('clk2fflogic')
    else:
        lines.append('async2sync')
        lines.append('dffunmap')
    lines.append('opt_clean')
    lines.append('write_smt2 -wires %s' % smt2)
    if task.get('pdr', False):
        # The same model as an AIGER for ABC's PDR (an unbounded proof of
        # every assertion at once); covers are checked by smtbmc
        lines += ['chformal -cover -remove', 'chformal -assume -early', 'formalff -clk2ff -ff2anyinit',
                  'setundef -undriven -anyseq', 'opt -keepdc -fast', 'techmap', 'opt -fast', 'dffunmap',
                  'aigmap', 'delete -output', 'write_aiger -I -B -zinit -map model.aim model.aig']
    return '\n'.join(lines) + '\n'


# Flop input ports: the combinational cone stops there
_FF_CUT = ':'.join('-%s[%s]' % (t, p) for t, p in (
    ('$dff', 'D,CLK'), ('$dffe', 'D,CLK,EN'), ('$adff', 'D,CLK,ARST'), ('$adffe', 'D,CLK,ARST,EN'),
    ('$sdff', 'D,CLK,SRST'), ('$sdffe', 'D,CLK,SRST,EN'), ('$sdffce', 'D,CLK,SRST,EN'),
    ('$aldff', 'D,CLK,AD,ALOAD'), ('$aldffe', 'D,CLK,AD,ALOAD,EN'), ('$dffsr', 'D,CLK,SET,CLR'),
    ('$dffsre', 'D,CLK,SET,CLR,EN')))


def comb_free_script(proof, task, proof_dir, rtl_dir, out):
    """Yosys script listing the harness inputs in the flop-cut input cone of
    the task's comb_free wires (empty: those wires come from flops only)."""
    files = [resolve(s, proof_dir, rtl_dir) for s in proof['files']]
    defines = ['-DFORMAL'] + ['-D' + d for d in proof.get('defines', []) + task.get('defines', [])]
    chp = ' '.join('-chparam %s %s' % (k, v) for k, v in sorted(task.get('params', {}).items()))
    wires = task['comb_free']
    sel = ' '.join('w:%s' % w for w in wires) + ' %u' * (len(wires) - 1)
    return '\n'.join(['read_verilog -formal -sv %s %s' % (' '.join(defines), ' '.join(files)),
                      'hierarchy -check -top %s %s' % (task.get('top', proof['top']), chp),
                      'proc', 'flatten', 'opt_clean',
                      'tee -q -o %s select -list %s %%ci*:%s i:* %%i' % (out, sel, _FF_CUT)]) + '\n'


def _run(cmd, cwd, timeout, log):
    t0 = time.time()
    try:
        p = subprocess.run(cmd, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           text=True, timeout=timeout)
        out, rc, to = p.stdout, p.returncode, False
    except subprocess.TimeoutExpired as e:
        out = e.stdout.decode() if isinstance(e.stdout, bytes) else (e.stdout or '')
        rc, to = -1, True
    with open(log, 'w') as f:
        f.write(out)
    return out, rc, to, time.time() - t0


_FAIL_RE  = re.compile(r'Assert failed in \S+: (\S+)')
_REACH_RE = re.compile(r'Reached cover statement .* at \S+: (\S+)')
_UNR_RE   = re.compile(r'Unreached cover statement at \S+: (\S+)')


def _status(out):
    if 'Status: PASSED' in out:
        return 'PASS'
    if 'Status: FAILED' in out:
        return 'FAIL'
    return 'ERROR'


def run_task(name, task_name, rtl_dir=None, work_root=None, depth=None, steps=('bmc', 'pdr', 'ind', 'cover'),
             keep_going=False):
    """Run one task. Returns a dict: status PASS/FAIL/ERROR/TIMEOUT, failed
    labels, per-step results and the run time."""
    proof     = load_proof(name)
    task      = proof['tasks'][task_name]
    proof_dir = os.path.join(FORMAL_DIR, name)
    rtl_dir   = rtl_dir or RTL_DIR
    work      = os.path.join(work_root or os.path.join(proof_dir, 'work'), task_name)
    os.makedirs(work, exist_ok=True)
    timeout   = task.get('timeout', proof.get('timeout', 600))
    depth     = depth or task['depth']
    res       = {'proof': name, 'task': task_name, 'depth': depth, 'steps': {}, 'failed': [], 'time': 0.0}

    ys = os.path.join(work, 'model.ys')
    with open(ys, 'w') as f:
        f.write(yosys_script(proof, task, proof_dir, rtl_dir, 'model.smt2'))
    out, rc, to, dt = _run(['yosys', '-q', '-l', 'yosys.log', '-s', 'model.ys'], work, timeout,
                           os.path.join(work, 'yosys.out'))
    res['time'] += dt
    if rc != 0:
        res['status'] = 'TIMEOUT' if to else 'ERROR'
        res['steps']['yosys'] = res['status']
        return res

    if task.get('comb_free') and 'bmc' in steps:
        with open(os.path.join(work, 'comb.ys'), 'w') as f:
            f.write(comb_free_script(proof, task, proof_dir, rtl_dir, 'comb.txt'))
        out, rc, to, dt = _run(['yosys', '-q', '-s', 'comb.ys'], work, timeout, os.path.join(work, 'comb.log'))
        res['time'] += dt
        hits = [l.strip() for l in open(os.path.join(work, 'comb.txt'))] if rc == 0 else []
        res['steps']['comb'] = 'ERROR' if rc != 0 else ('FAIL' if hits else 'PASS')
        if rc != 0 or hits:
            if hits:
                res['failed'].append('comb_free')
                res['comb_inputs'] = [h.split('/')[-1] for h in hits]
            res['status'] = res['steps']['comb']
            return res

    base = ['yosys-smtbmc', '-s', 'z3', '--presat']
    plan = []
    if 'bmc' in steps:
        kg = ['--keep-going'] if keep_going else []
        plan.append(('bmc', base + kg + ['-t', str(depth), '--dump-vcd', 'bmc.vcd', 'model.smt2']))
    if 'pdr' in steps and task.get('pdr', False):
        plan.append(('pdr', ['yosys-abc', '-c', 'read_aiger model.aig; fold; strash; pdr']))
    if 'ind' in steps and task.get('induction', False):
        plan.append(('ind', base + ['-i', '-t', str(depth), '--dump-vcd', 'ind.vcd', 'model.smt2']))
    if 'cover' in steps and task.get('cover', False):
        plan.append(('cover', base + ['-c', '-t', str(task.get('cover_depth', depth)),
                                      '--dump-vcd', 'cover.vcd', 'model.smt2']))
    status = 'PASS'
    for step, cmd in plan:
        out, rc, to, dt = _run(cmd, work, timeout, os.path.join(work, step + '.log'))
        res['time'] += dt
        if to:
            st = 'TIMEOUT'
        elif step == 'pdr':
            st = 'PASS' if 'Property proved' in out else 'FAIL' if 'was asserted in frame' in out else 'ERROR'
        else:
            st = _status(out)
        if step == 'cover':
            res['covers'] = len(set(_REACH_RE.findall(out)))
            unr = _UNR_RE.findall(out)
            if unr:
                res['unreached'] = unr
        res['steps'][step] = st
        for l in _FAIL_RE.findall(out):
            if l not in res['failed']:
                res['failed'].append(l)
        if st != 'PASS':
            status = st if status == 'PASS' else status
            if step == 'bmc':
                break
    res['status'] = status
    if task.get('expect_fail') and 'bmc' in res['steps']:
        # A documented counterexample (a finding kept as a software rule): the
        # bounded check must fail, on the expected assertion
        hit = res['steps']['bmc'] == 'FAIL' and any(l in task['expect_fail'] for l in res['failed'])
        res['steps']['bmc'] = 'XFAIL' if hit else res['steps']['bmc']
        res['status'] = 'PASS' if hit else 'FAIL'
    return res


def mutation_edits(mut):
    """[(file, from, to)]: one edit ("file", "from", "to") or several
    ("edits": [[file, from, to], ...])."""
    if 'edits' in mut:
        return [tuple(e) for e in mut['edits']]
    return [(mut['file'], mut['from'], mut['to'])]


def apply_mutation(mut, rtl_src, dst):
    """Copy the RTL directory to dst and apply the mutation's exact-text
    edits (each must match exactly once)."""
    shutil.copytree(rtl_src, dst)
    for fname, old, new in mutation_edits(mut):
        path = os.path.join(dst, fname[4:] if fname.startswith('rtl:') else fname)
        with open(path) as f:
            text = f.read()
        n = text.count(old)
        if n != 1:
            raise RuntimeError('mutation %s: the edit matches %d times in %s' % (mut['name'], n, fname))
        with open(path, 'w') as f:
            f.write(text.replace(old, new))


_LABEL_RE = re.compile(r'\b(a_\w+)\s*:\s*assert\b')


def assert_labels(name):
    """The a_* assertion labels of a proof's harness files (h_* labels are
    lemmas of the reference model, strengthening the induction)."""
    proof = load_proof(name)
    labels = []
    for spec in proof['files']:
        if ':' in spec:
            continue
        with open(os.path.join(FORMAL_DIR, name, spec)) as f:
            for l in _LABEL_RE.findall(f.read()):
                if l not in labels:
                    labels.append(l)
    return labels


def run_mutation(name, mut):
    """Bounded check of the mutation's task on a mutated copy of the RTL. The
    mutation is killed when the check fails on one of the expected labels."""
    proof = load_proof(name)
    tmp = tempfile.mkdtemp(prefix='blns_fv_mut_')
    try:
        apply_mutation(mut, RTL_DIR, os.path.join(tmp, 'rtl'))
        work_root = os.path.join(FORMAL_DIR, name, 'work', 'mut')
        os.makedirs(work_root, exist_ok=True)
        tname = mut['task']
        res = run_task(name, tname, rtl_dir=os.path.join(tmp, 'rtl'),
                       work_root=os.path.join(work_root, mut['name']),
                       depth=mut.get('depth', proof['tasks'][tname]['depth']), steps=('bmc',),
                       keep_going=mut.get('keep_going', True))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    hit = [l for l in res['failed'] if any(l == e or l.startswith(e) for e in mut['expect'])]
    res['killed'] = res['status'] == 'FAIL' and bool(hit)
    res['mutation'] = mut['name']
    return res
