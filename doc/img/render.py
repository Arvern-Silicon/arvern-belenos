#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern System IPs
#         / \__/ \          Module:    render
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# File Name          : render.py
# Module Description : Render every diagram source file in this directory to
#                      SVG, with a white background rect so the result stays
#                      readable on a dark page (e.g. GitHub dark mode).
#
#                      Handled source types:
#                        *.json -> WaveDrom timing diagrams (needs `wavedrom`
#                                  Python package: pip install wavedrom);
#                                  register bit fields ({reg: ...}) go through
#                                  the Node wavedrom-cli (npx, needs Node.js),
#                                  which can rotate the field names
#                        *.dot  -> Graphviz state / block diagrams (needs the
#                                  graphviz `dot` binary in PATH)
#
#                      The *.json and *.dot sources are hand-written (figures.py
#                      makes only the *.drawio.svg figures); the register
#                      figures reg_*.json are checked against
#                      sw/include/belenos_regs.h by doc/tools/check_reg_figures.py.
#                      Re-render only the files changed (python3 render.py
#                      reg_status.json ...), so the other SVGs stay as they are.
#----------------------------------------------------------------------------
"""
Usage:
    python3 render.py                        # render every supported file in this dir
    python3 render.py fsm.dot single_read.json   # render specific files
"""

import os
import re
import subprocess
import sys

# ---- optional toolchain probes (single check, cached) ----------------------

try:
    import wavedrom
    HAS_WAVEDROM = True
except ImportError:
    wavedrom = None
    HAS_WAVEDROM = False

try:
    subprocess.run(['dot', '-V'], capture_output=True, check=True)
    HAS_DOT = True
except (FileNotFoundError, subprocess.CalledProcessError):
    HAS_DOT = False


WHITE_BG_RECT = ('<rect data-dark-mode-bg="true" '
                 'width="100%" height="100%" fill="#ffffff"/>')


def patch_white_background(svg_path):
    """Inject a white background <rect> into the SVG so the diagram stays
    readable on a dark page. Idempotent: re-running on a patched SVG is a
    no-op. Safe to call on SVGs that already have their own background
    (the extra white rect is visually a no-op there)."""
    with open(svg_path) as f:
        content = f.read()
    if 'data-dark-mode-bg' in content:
        return
    content = re.sub(r'(<svg[^>]*>)',
                     lambda m: m.group(0) + WHITE_BG_RECT,
                     content, count=1)
    with open(svg_path, 'w') as f:
        f.write(content)


def render_wavedrom_cli(json_path, svg_path):
    subprocess.run(['npx', '-y', 'wavedrom-cli', '-i', json_path, '-s', svg_path],
                   check=True, capture_output=True)
    patch_white_background(svg_path)


def render_wavedrom(json_path, svg_path):
    with open(json_path) as f:
        json_str = f.read()
    if re.match(r'\s*\{\s*reg\s*:', json_str):
        render_wavedrom_cli(json_path, svg_path)
        return
    assert wavedrom is not None, "wavedrom package not installed"

    # Pick up an optional `config.fontsize` hint. wavedrompy ignores it,
    # so we apply it as a post-process step below.
    fontsize = None
    try:
        import json as _json
        cfg = _json.loads(json_str).get('config', {})
        if isinstance(cfg, dict):
            fs = cfg.get('fontsize')
            if isinstance(fs, (int, float)):
                fontsize = fs
    except Exception:
        pass  # not strict JSON — silently fall back to default font size

    svg_obj = wavedrom.render(json_str)
    if svg_obj is None:
        raise RuntimeError("wavedrom.render returned None for {}".format(json_path))
    svg_obj.saveas(svg_path)

    if fontsize is not None:
        override_text_fontsize(svg_path, fontsize)
    patch_white_background(svg_path)


def override_text_fontsize(svg_path, fontsize):
    """Override the generic `text{font-size:Npt}` CSS rule in the SVG so
    bus labels fit in narrow cells. The .h1..h6 heading classes keep their
    own larger font-size."""
    with open(svg_path) as f:
        content = f.read()
    new_content, n = re.subn(r'(text\s*\{\s*font-size:)\d+pt',
                              r'\g<1>{}pt'.format(fontsize),
                              content, count=1)
    if n > 0:
        with open(svg_path, 'w') as f:
            f.write(new_content)


def render_dot(dot_path, svg_path):
    subprocess.run(['dot', '-Tsvg', dot_path, '-o', svg_path], check=True)
    patch_white_background(svg_path)


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))

    args = sys.argv[1:]
    if args:
        sources = [a if os.path.isabs(a) else os.path.join(script_dir, a)
                   for a in args]
    else:
        sources = sorted(
            os.path.join(script_dir, f)
            for f in os.listdir(script_dir)
            if f.endswith('.json') or f.endswith('.dot')
        )

    if not sources:
        print("No .json or .dot files found in {}".format(script_dir))
        return 1

    errors = 0
    for src in sources:
        if not os.path.isfile(src):
            print("  MISSING: {}".format(src))
            errors += 1
            continue
        base, ext = os.path.splitext(os.path.basename(src))
        svg_path = os.path.join(script_dir, base + '.svg')
        try:
            if ext == '.json':
                if not HAS_WAVEDROM and not os.path.basename(src).startswith('reg_'):
                    print("  SKIP:    {} (need: pip install wavedrom)".format(os.path.basename(src)))
                    errors += 1
                    continue
                render_wavedrom(src, svg_path)
                print("  rendered {}.json -> {}.svg".format(base, base))
            elif ext == '.dot':
                if not HAS_DOT:
                    print("  SKIP:    {} (need: graphviz `dot` in PATH)".format(os.path.basename(src)))
                    errors += 1
                    continue
                render_dot(src, svg_path)
                print("  rendered {}.dot -> {}.svg".format(base, base))
            else:
                print("  SKIP:    {} (unsupported extension {})".format(os.path.basename(src), ext))
        except Exception as e:
            print("  ERROR    {}: {}".format(os.path.basename(src), e))
            errors += 1

    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main())
