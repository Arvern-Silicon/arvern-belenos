#!/usr/bin/env python3
#----------------------------------------------------------------------------
#          _    _           Family:    aRVern Graphic Controller
#         / \__/ \          Script:    figures.py
#        /   /\   \         --------------------------------------------
#    ===/   /=========      Copyright: (c) 2026, aRVern-dev
#      /   / RV \   \       Contact:   arvernsilicon@gmail.com
#     /___/______\___\      GitHub:    https://github.com/Arvern-Silicon
#
# SPDX-License-Identifier: BSD-3-Clause
# Full license text is available in the LICENSE file at the repository root.
#----------------------------------------------------------------------------
# Generate the documentation figures as draw.io diagrams: the block diagram,
# the SoC view, the GPU pipeline, the GPU command gallery and the drawings
# computed from data (pixel packing, scan orders, rectangle walks, hardware
# palettes, frame pointers).
# Each is exported by the draw.io desktop CLI to <name>.drawio.svg next to
# this script, with the diagram embedded (the SVG opens for editing in
# draw.io). The palette values are the hardware tables of
# rtl/verilog/blns_bk_hwcol.v.
#
#   python3 figures.py            # regenerate every <name>.drawio.svg
#   python3 figures.py --drawio   # write the <name>.drawio sources only
#   DRAWIO=/path/to/drawio        # CLI location (default: the macOS app)
#----------------------------------------------------------------------------
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DRAWIO = os.environ.get('DRAWIO', '/Applications/draw.io.app/Contents/MacOS/draw.io')
NO_EXPORT = '--drawio' in sys.argv

INK    = '#1f2328'
GRID   = '#8c959f'
MUTED  = '#57606a'
ACCENT = '#cf222e'
BLUE   = '#0969da'
FILL   = '#ddf4ff'
FILL2  = '#f0f9ff'
SHADE  = '#f6f8fa'
YELLOW = '#fff8c5'
ROSE   = '#ffebe9'
GREEN  = '#dafbe1'
FONT   = 'fontFamily=Helvetica;'
MONO   = 'fontFamily=Menlo;'


def esc(s):
    return (str(s).replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;')
            .replace('"', '&quot;'))


class Drawing:
    """mxGraph cells: boxes, free text, lines, connectors between boxes."""

    def __init__(self):
        self.cells = []
        self.n = 0

    def _id(self, i=None):
        if i:
            return i
        self.n += 1
        return 'c%d' % self.n

    def box(self, x, y, w, h, label='', fill='#ffffff', stroke=INK, size=11, style='', i=None,
            parent='1', rounded=True, bold=False):
        st = ('rounded=%d;arcSize=10;whiteSpace=wrap;html=1;fillColor=%s;strokeColor=%s;fontSize=%s;'
              % (1 if rounded else 0, fill, stroke, size)) + FONT + style
        if bold:
            st += 'fontStyle=1;'
        i = self._id(i)
        self.cells.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="%s">'
                          '<mxGeometry x="%g" y="%g" width="%g" height="%g" as="geometry"/></mxCell>'
                          % (i, esc(label), st, parent, x, y, w, h))
        return i

    def text(self, x, y, s, size=11, align='center', color=INK, bold=False, w=None, h=18, mono=False,
             parent='1'):
        w = w if w is not None else max(20, len(str(s)) * size * 0.62)
        if align == 'center':
            x0 = x - w / 2
        elif align == 'right':
            x0 = x - w
        else:
            x0 = x
        st = ('text;html=1;whiteSpace=wrap;align=%s;verticalAlign=middle;fontSize=%s;fontColor=%s;'
              % (align, size, color)) + (MONO if mono else FONT) + ('fontStyle=1;' if bold else '')
        i = self._id()
        self.cells.append('<mxCell id="%s" value="%s" style="%s" vertex="1" parent="%s">'
                          '<mxGeometry x="%g" y="%g" width="%g" height="%g" as="geometry"/></mxCell>'
                          % (i, esc(s), st, parent, x0, y - h / 2, w, h))
        return i

    def line(self, pts, color=INK, width=1.0, arrow=True, dashed=False, opacity=100, start_arrow=False):
        st = ('endArrow=%s;endFill=1;endSize=5;html=1;strokeColor=%s;strokeWidth=%s;opacity=%d;'
              % ('block' if arrow else 'none', color, width, opacity))
        if start_arrow:
            st += 'startArrow=block;startFill=1;startSize=6;'
        if dashed:
            st += 'dashed=1;'
        i = self._id()
        g = ('<mxGeometry relative="1" as="geometry"><mxPoint x="%g" y="%g" as="sourcePoint"/>'
             '<mxPoint x="%g" y="%g" as="targetPoint"/>' % (pts[0][0], pts[0][1], pts[-1][0], pts[-1][1]))
        if len(pts) > 2:
            g += '<Array as="points">' + ''.join('<mxPoint x="%g" y="%g"/>' % p for p in pts[1:-1]) + '</Array>'
        g += '</mxGeometry>'
        self.cells.append('<mxCell id="%s" style="%s" edge="1" parent="1">%s</mxCell>' % (i, st, g))

    def dot(self, x, y, r=5, color=INK):
        i = self._id()
        self.cells.append('<mxCell id="%s" value="" style="ellipse;fillColor=%s;strokeColor=none;" vertex="1" '
                          'parent="1"><mxGeometry x="%g" y="%g" width="%g" height="%g" as="geometry"/></mxCell>'
                          % (i, color, x - r, y - r, 2 * r, 2 * r))

    def link(self, s, t, label='', parent='1', both=False, dashed=False, ex=None, en=None, pts=None):
        st = ('edgeStyle=orthogonalEdgeStyle;rounded=1;html=1;endArrow=block;endFill=1;endSize=6;'
              'strokeColor=%s;fontSize=9;labelBackgroundColor=#ffffff;' % INK) + FONT
        if both:
            st += 'startArrow=block;startFill=1;startSize=6;'
        if dashed:
            st += 'dashed=1;'
        if ex:
            st += 'exitX=%s;exitY=%s;exitDx=0;exitDy=0;' % ex
        if en:
            st += 'entryX=%s;entryY=%s;entryDx=0;entryDy=0;' % en
        g = '<mxGeometry relative="1" as="geometry">'
        if pts:
            g += '<Array as="points">' + ''.join('<mxPoint x="%g" y="%g"/>' % p for p in pts) + '</Array>'
        g += '</mxGeometry>'
        self.cells.append('<mxCell id="%s" value="%s" style="%s" edge="1" parent="%s" source="%s" target="%s">%s</mxCell>'
                          % (self._id(), esc(label), st, parent, s, t, g))

    def save(self, name):
        xml = ('<mxGraphModel grid="0" page="0" background="#ffffff"><root>'
               '<mxCell id="0"/><mxCell id="1" parent="0"/>' + ''.join(self.cells) + '</root></mxGraphModel>\n')
        if NO_EXPORT:
            out = os.path.join(HERE, name + '.drawio')
            with open(out, 'w') as f:
                f.write(xml)
        else:
            with tempfile.TemporaryDirectory() as tmp:
                src = os.path.join(tmp, name + '.drawio')
                with open(src, 'w') as f:
                    f.write(xml)
                out = os.path.join(HERE, name + '.drawio.svg')
                subprocess.run([DRAWIO, '-x', '-f', 'svg', '-e', '-b', '10', '-o', out, src],
                               check=True, capture_output=True, timeout=120)
            with open(out) as f:                     # light colours on a dark page too
                svg = f.read().replace('color-scheme: light dark;', 'color-scheme: light;', 1)
            with open(out, 'w') as f:
                f.write(svg)
        print('  wrote', os.path.basename(out))


def b(name, sub):
    return '<b>%s</b><br>%s' % (name, sub)


def small(t):
    return '<font style="font-size:9px">%s</font>' % t


PORT = ('shape=step;perimeter=stepPerimeter;fixedSize=1;size=12;')
MEM = ('shape=cylinder3;boundedLbl=1;size=8;')
CONT = ('arcSize=2;dashed=1;verticalAlign=top;align=left;spacingLeft=10;spacingTop=4;fontStyle=1;'
        'container=1;collapsible=0;')


#=============================================================================
# 1) Block diagram
#=============================================================================
def block():
    d = Drawing()
    d.box(0, 200, 120, 60, 'AHB-Lite<br>register port<br>' + small('4 KB, word'), SHADE, MUTED, style=PORT, i='rport', rounded=False)
    d.box(0, 500, 120, 60, 'AHB-Lite<br>VRAM window<br>' + small('byte / half / word'), SHADE, MUTED, style=PORT, i='vport', rounded=False)
    d.box(160, 40, 860, 560, 'belenos_core', 'none', GRID, size=12, style=CONT, i='core')
    d.box(30, 160, 140, 60, b('blns_ahb_reg', 'register bus'), FILL, i='ahbreg', parent='core')
    d.box(240, 40, 160, 60, b('blns_regs', 'global registers,<br>frame pointers, IRQ'), FILL, i='regs', parent='core')
    d.box(460, 40, 150, 60, b('blns_refresh', 'refresh timer,<br>FRAME_CNT'), FILL, i='refresh', parent='core')
    d.box(460, 150, 150, 60, b('blns_backend', 'fetch · unpack · colour'), YELLOW, i='bk', parent='core')
    d.box(680, 40, 150, 60, b('blns_lut', 'LUT window + arbiter'), FILL, i='lut', parent='core')
    d.box(680, 330, 150, 60, b('blns_vram_arb', 'VRAM arbiter'), YELLOW, i='arb', parent='core')
    d.box(240, 465, 160, 50, b('blns_ahb_vram', 'VRAM window'), FILL, i='ahbv', parent='core')
    d.box(30, 280, 600, 120, 'blns_gpu', FILL2, size=11,
          style='arcSize=6;verticalAlign=top;align=left;spacingLeft=8;spacingTop=2;fontStyle=1;container=1;collapsible=0;',
          i='gpu', parent='core')
    d.box(15, 40, 120, 60, b('command FIFO', '+ list fetch'), FILL, size=10, i='gfifo', parent='gpu')
    d.box(160, 40, 120, 60, b('decoder', 'settings, errors,<br>fences'), FILL, size=10, i='gdec', parent='gpu')
    d.box(305, 40, 130, 60, b('set-up', 'start address, clip<br>trim, (u, v) start'), FILL, size=10, i='gsetup', parent='gpu')
    d.box(460, 40, 125, 60, b('pixel engine', 'word cache, write<br>buffer, triangle walk'), FILL, size=10, i='gpx', parent='gpu')
    d.box(1250, 50, 110, 70, 'LUT macro<br>' + small('512 × 24'), '#ffffff', style=MEM, i='lutm', rounded=False)
    d.box(1080, 180, 120, 60, b('blns_dbi', 'DBI driver<br>8080 / SPI'), ROSE, i='dbi')
    d.box(1250, 180, 110, 60, 'panel<br>' + small('ILI9341 class'), '#ffffff', style='shape=cube;size=8;', i='pan', rounded=False)
    d.box(1080, 265, 150, 50, 'BDI<br>' + small('own driver (DIF_TYPE 0)'), SHADE, MUTED, style=PORT, i='ext', rounded=False)
    d.box(1080, 365, 120, 70, 'VRAM macro<br>' + small('32-bit, 1-cycle read'), '#ffffff', style=MEM, i='vram', rounded=False)
    d.link('rport', 'ahbreg')
    d.link('ahbreg', 'regs', parent='core', ex=('0.5', '0'), en=('0', '0.5'))
    d.link('ahbreg', 'gfifo', parent='core', ex=('0.5', '1'), en=('0.5', '0'))
    d.link('ahbreg', 'dbi', 'BDI register window', ex=('0.25', '0'), en=('0.5', '0'), pts=[(225, 15), (1140, 15)])
    d.link('regs', 'refresh', parent='core', both=True)
    d.link('refresh', 'bk', 'refresh_trig', parent='core', ex=('0.5', '1'), en=('0.5', '0'))
    d.link('bk', 'lut', parent='core', ex=('1', '0.25'), en=('0.25', '1'))
    d.link('lut', 'lutm', both=True)
    d.link('bk', 'dbi', 'pixel stream (RGB888)', ex=('1', '0.6'), en=('0', '0.5'))
    d.link('bk', 'ext', ex=('0.75', '1'), en=('0', '0.5'), dashed=True)
    d.link('bk', 'arb', 'urgent', parent='core', ex=('0.5', '1'), en=('0.6', '0'), pts=[(535, 240), (770, 240)])
    d.link('gpx', 'arb', parent='core', both=True, ex=('1', '0.5'), en=('0', '0.6'))
    d.link('vport', 'ahbv')
    d.link('ahbv', 'arb', parent='core', both=True, ex=('1', '0.5'), en=('0.5', '1'))
    d.link('arb', 'vram', both=True)
    d.link('dbi', 'pan')
    d.link('gfifo', 'gdec', parent='gpu')
    d.link('gdec', 'gsetup', parent='gpu')
    d.link('gsetup', 'gpx', parent='gpu')
    d.save('belenos_block')


#=============================================================================
# 2) Belenos in an aRVern SoC
#=============================================================================
def soc():
    d = Drawing()
    d.box(0, 60, 150, 60, b('aRVern core', '+ Debug Module'), YELLOW, i='core')
    d.box(0, 170, 150, 50, b('debugger', 'system-bus access'), SHADE, MUTED, i='dbg')
    d.box(220, 90, 140, 100, b('AHB-Lite', 'interconnect'), SHADE, MUTED, i='ic')
    d.box(440, 60, 170, 160, '<b>belenos</b>', FILL, style='strokeWidth=2;', size=13, i='bl')
    d.box(690, 40, 120, 60, 'VRAM macro', '#ffffff', style=MEM, i='vram', rounded=False)
    d.box(690, 120, 120, 60, 'LUT macro', '#ffffff', style=MEM, i='lutm', rounded=False)
    d.box(690, 200, 120, 60, 'panel<br>' + small('8080 / SPI'), '#ffffff', style='shape=cube;size=8;', i='pan', rounded=False)
    d.box(480, 290, 170, 50, b('PLIC', 'or platform IRQ'), SHADE, MUTED, i='plic')
    d.box(220, 290, 140, 50, 'clock gate (ICG)', SHADE, MUTED, style='shape=trapezoid;perimeter=trapezoidPerimeter;fixedSize=1;size=14;flipV=1;', i='icg', rounded=False)
    d.link('core', 'ic', 'data port', ex=('1', '0.5'), en=('0', '0.3'))
    d.link('dbg', 'ic', ex=('1', '0.5'), en=('0', '0.8'))
    d.link('ic', 'bl', 'register port +<br>VRAM window', ex=('1', '0.5'), en=('0', '0.5'))
    d.link('bl', 'vram', both=True, ex=('1', '0.15'), en=('0', '0.5'))
    d.link('bl', 'lutm', both=True, ex=('1', '0.55'), en=('0', '0.5'))
    d.link('bl', 'pan', ex=('1', '0.9'), en=('0', '0.5'))
    d.link('bl', 'plic', 'irq_o', ex=('0.7', '1'), en=('0.47', '0'))
    d.link('plic', 'core', ex=('0.5', '1'), en=('0', '0.5'), pts=[(565, 375), (-25, 375), (-25, 90)])
    d.link('core', 'bl', 'dbg_stoptime_i', dashed=True, ex=('0.5', '0'), en=('0.3', '0'), pts=[(75, 20), (491, 20)])
    d.link('bl', 'icg', 'hclk_en_o', dashed=True, ex=('0.1', '1'), en=('1', '0.5'), pts=[(457, 315)])
    d.link('icg', 'bl', 'hclk', ex=('0.5', '0'), en=('0', '0.85'), pts=[(290, 245), (415, 245), (415, 196)])
    d.save('belenos_soc')


#=============================================================================
# 3) GPU pipeline (new)
#=============================================================================
def gpu_pipeline():
    d = Drawing()
    d.text(490, 10, 'GPU: from the command words to the VRAM', size=13, bold=True, w=700)
    d.box(-15, 34, 480, 136, 'command path', 'none', GRID, size=11, style='arcSize=4;dashed=1;verticalAlign=top;align=left;spacingLeft=8;fontStyle=1;fontColor=%s;' % MUTED)
    d.box(495, 34, 500, 136, 'pixel engine (blns_gpu_px): three stages, one token per cycle', 'none', GRID, size=11, style='arcSize=4;dashed=1;verticalAlign=top;align=left;spacingLeft=8;fontStyle=1;fontColor=%s;' % MUTED)
    stages = [
        ('fifo', 'command FIFO', 'words pushed by the CPU,<br>or read from VRAM (CALL)', FILL),
        ('dec', 'decoder', 'settings kept between<br>commands; errors, fences', FILL),
        ('setup', 'set-up', 'start address, clip trim,<br>(u, v) and gradient start', FILL),
        ('a', 'A: address', 'a pixel, or a whole word<br>of a FILL; triangle walk', YELLOW),
        ('f', 'F: fetch', 'source word: cache,<br>read ahead or a read', YELLOW),
        ('w', 'W: merge', 'pixel function into<br>a word buffer', YELLOW),
    ]
    for k, (i, name, sub, col) in enumerate(stages):
        x = k * 170 + (10 if k >= 3 else 0)
        d.box(x, 66, 140, 84, '<b>%s</b><br><font style="font-size:9px;color:%s">%s</font>' % (name, MUTED, sub),
              col, i=i, size=12)
    for a, c in (('fifo', 'dec'), ('dec', 'setup'), ('setup', 'a'), ('a', 'f'), ('f', 'w')):
        d.link(a, c)
    d.box(880, 250, 110, 50, b('write-back slot', 'a finished word'), GREEN, size=10)
    d.box(495, 350, 500, 50, '<b>VRAM arbiter</b> (shared with refresh, AHB window)', YELLOW, size=11)
    d.line([(935, 150), (935, 250)])
    d.line([(935, 300), (935, 350)])
    d.text(945, 325, 'word write', size=9, align='left', color=MUTED, w=80)
    d.line([(860, 350), (860, 150)], start_arrow=True)
    d.text(850, 225, 'destination<br>read', size=9, align='right', color=MUTED, w=80, h=30)
    d.line([(755, 350), (755, 150)], start_arrow=True)
    d.text(745, 225, 'source read', size=9, align='right', color=MUTED, w=80)
    d.line([(20, 150), (20, 375), (495, 375)], start_arrow=True)
    d.text(30, 360, 'list words (CALL)', size=9, align='left', color=MUTED, w=120)
    d.text(250, 230, 'run-ahead (GPU_RUNAHEAD_EN): the decoder and set-up prepare the next command '
           'while the pixel engine draws this one', size=9, color=MUTED, w=420, h=30)
    d.text(490, 425, 'Port priority: destination read, source read, the slot when a word waits for it, '
           'the read ahead, the slot otherwise; one read in flight.', size=10, color=MUTED, w=1000)
    d.save('gpu_pipeline')


#=============================================================================
# 4) Pixel packing in a 32-bit VRAM word (LSB first)
#=============================================================================
def bpp_packing():
    d = Drawing()
    modes = [(16, 'GFX_MODE 4 · 16 bpp', 'RGB565'), (8, 'GFX_MODE 3 · 8 bpp', 'RGB332 or LUT index'),
             (4, 'GFX_MODE 2 · 4 bpp', 'CGA or LUT index'), (2, 'GFX_MODE 1 · 2 bpp', 'palette or LUT index'),
             (1, 'GFX_MODE 0 · 1 bpp', 'BG / FG or LUT index')]
    bw, x0, y0, rowh = 22, 190, 46, 52
    d.text(x0 + 16 * bw, 12, 'A 32-bit VRAM word: pixel k sits at bits [k·bpp + bpp − 1 : k·bpp] (LSB first)',
           size=13, bold=True, w=760)
    for bit in range(32):
        d.text(x0 + (31 - bit) * bw + bw / 2, y0 - 10, str(bit), size=8, color=GRID, w=bw)
    for r, (bpp, name, fmt) in enumerate(modes):
        y = y0 + r * rowh
        d.text(x0 - 12, y + 11, name, size=11, align='right', bold=True, w=170)
        d.text(x0 - 12, y + 26, fmt, size=9, align='right', color=MUTED, w=170)
        for k in range(32 // bpp):
            xr = x0 + (31 - (k * bpp + bpp - 1)) * bw
            d.box(xr, y, bpp * bw, 34, ('px %d' % k) if bpp >= 4 else str(k), FILL if k % 2 == 0 else '#ffffff',
                  GRID, size=10 if bpp >= 2 else 8, rounded=False)
    d.save('bpp_packing')


#=============================================================================
# 5) Scan order: DISP_CFG for the eight X / Y / CL combinations
#=============================================================================
def scan_order(x_swap, y_swap, cl_swap, w, h):
    xs = list(range(w))[::-1] if x_swap else list(range(w))
    ys = list(range(h))[::-1] if y_swap else list(range(h))
    order = []
    if cl_swap:
        for x in xs:
            for y in ys:
                order.append(y * w + x)
    else:
        for y in ys:
            for x in xs:
                order.append(y * w + x)
    return order


def disp_cfg_matrix():
    d = Drawing()
    w, h, cell, pad = 8, 5, 20, 26
    gw, gh = w * cell, h * cell
    colw = gw * 2 + 3 * pad + 60
    rowh = w * cell + 64
    combos = [(0, 0, 0), (0, 0, 1), (1, 0, 0), (1, 0, 1), (0, 1, 0), (0, 1, 1), (1, 1, 0), (1, 1, 1)]
    d.text(colw, 12, 'DISP_CFG: the order the refresh reads the frame buffer (left), the panel filled '
           'row by row (right)', size=13, bold=True, w=2 * colw)
    for n, (xs_, ys_, cl) in enumerate(combos):
        ox = (n % 2) * colw
        oy = 40 + (n // 2) * rowh
        name = ' + '.join([t for t, v in (('X', xs_), ('Y', ys_), ('CL', cl)) if v]) or 'no swap'
        d.text(ox + colw / 2, oy + 6, 'DISP_CFG = %d  (%s)' % ((xs_ << 2) | (ys_ << 1) | cl, name), size=11,
               bold=True, color=BLUE, w=colw)
        order = scan_order(xs_, ys_, cl, w, h)
        fx, fy = ox + pad, oy + 24
        for y in range(h):
            for x in range(w):
                d.box(fx + x * cell, fy + y * cell, cell, cell, str(y * w + x),
                      FILL if (x + y) % 2 else '#ffffff', GRID, size=8, rounded=False)
        d.text(fx + gw / 2, fy + gh + 12, 'frame buffer', size=9, color=MUTED, w=gw)
        run = h if cl else w
        ctr = lambda idx: (fx + (idx % w) * cell + cell / 2, fy + (idx // w) * cell + cell / 2)
        for r in range(2):
            (ax, ay), (bx, by) = ctr(order[r * run]), ctr(order[r * run + run - 1])
            if cl:
                sg = 1 if by > ay else -1
                d.line([(ax + 7, ay - sg * 6), (bx + 7, by + sg * 8)], ACCENT, 1.5)
            else:
                sg = 1 if bx > ax else -1
                d.line([(ax - sg * 6, ay + 6), (bx + sg * 8, by + 6)], ACCENT, 1.5)
        px = fx + gw + pad + 24
        d.line([(fx + gw + 8, fy + gh / 2), (px - 8, fy + gh / 2)], INK, 1)
        pw = h if cl else w
        for k, idx in enumerate(order):
            d.box(px + (k % pw) * cell, fy + (k // pw) * cell, cell, cell, str(idx), '#ffffff', GRID, size=8,
                  rounded=False)
        d.text(px + pw * cell / 2, fy + (w if cl else h) * cell + 12, 'panel', size=9, color=MUTED, w=80)
    d.save('disp_cfg_orientations')


#=============================================================================
# 6) Rectangle walks: start corner and direction per swap
#=============================================================================
def rect_walks():
    d = Drawing()
    W, H, rx, ry, rw, rh, cell = 10, 6, 2, 1, 5, 3, 18
    combos = [(0, 0, 0), (1, 0, 0), (0, 1, 0), (1, 1, 0), (0, 0, 1), (1, 0, 1), (0, 1, 1), (1, 1, 1)]
    bw, bh = W * cell + 40, H * cell + 64
    d.text(2 * bw, 12, 'Rectangle walk of a GPU operation: the base address is the first pixel '
           'visited (●), the swaps set the direction', size=13, bold=True, w=4 * bw)
    for n, (xs_, ys_, cl) in enumerate(combos):
        ox, oy = (n % 4) * bw, 40 + (n // 4) * bh
        name = ' + '.join([t for t, v in (('X', xs_), ('Y', ys_), ('CL', cl)) if v]) or 'no swap'
        d.text(ox + bw / 2, oy + 4, 'swap = %d  (%s)' % ((xs_ << 2) | (ys_ << 1) | cl, name), size=11, bold=True,
               color=BLUE, w=bw)
        gx, gy = ox + 20, oy + 20
        for y in range(H):
            for x in range(W):
                inside = rx <= x < rx + rw and ry <= y < ry + rh
                d.box(gx + x * cell, gy + y * cell, cell, cell, '', FILL if inside else '#ffffff', GRID, rounded=False)
        xsq = list(range(rx, rx + rw))[::-1] if xs_ else list(range(rx, rx + rw))
        ysq = list(range(ry, ry + rh))[::-1] if ys_ else list(range(ry, ry + rh))
        runs = [[(x, y) for y in ysq] for x in xsq] if cl else [[(x, y) for x in xsq] for y in ysq]
        c = lambda p: (gx + p[0] * cell + cell / 2, gy + p[1] * cell + cell / 2)
        for k, r in enumerate(runs):
            d.line([c(r[0]), c(r[-1])], ACCENT, 2)
            if k + 1 < len(runs):
                d.line([c(r[-1]), c(runs[k + 1][0])], GRID, 1, arrow=False, dashed=True)
        a = c(runs[0][0])
        d.dot(a[0], a[1], 5)
        d.text(ox + bw / 2, gy + H * cell + 12, 'WIDTH = run length (rows)' if cl else 'WIDTH = run length (pixels)',
               size=9, color=MUTED, w=bw)
    d.save('rect_walks')


#=============================================================================
# 7) Hardware colour tables (blns_bk_hwcol.v)
#=============================================================================
CGA = [0x0000, 0x0015, 0x0560, 0x0575, 0xA800, 0xA815, 0xAAA0, 0xAD75,
       0x5AAB, 0x5ABF, 0x5FEB, 0x5FFF, 0xFAAB, 0xFABF, 0xFFEB, 0xFFFF]
CGA_NAMES = ['black', 'blue', 'green', 'cyan', 'red', 'magenta', 'brown', 'light gray',
             'gray', 'light blue', 'light green', 'light cyan', 'light red', 'light magenta',
             'yellow', 'white']
PALETTES = [(0, [10, 12, 14]), (1, [2, 4, 6]), (2, [11, 13, 15]), (3, [3, 5, 7]),
            (4, [11, 12, 15]), (5, [3, 4, 7])]


def rgb565(v):
    r, g, bb = (v >> 11) & 0x1F, (v >> 5) & 0x3F, v & 0x1F
    return '#%02x%02x%02x' % ((r << 3) | (r >> 2), (g << 2) | (g >> 4), (bb << 3) | (bb >> 2))


def dark(v):
    c = rgb565(v)
    r, g, bb = int(c[1:3], 16), int(c[3:5], 16), int(c[5:7], 16)
    return 0.299 * r + 0.587 * g + 0.114 * bb < 140


def palettes():
    d = Drawing()
    sw, sh, x0 = 62, 38, 200
    d.text((x0 + 16 * sw) / 2, 12, 'Hardware colour tables (LUT_CFG.SW_LUT_EN = 0)', size=13, bold=True, w=900)
    y = 40
    d.text(0, y + 12, '4 bpp: CGA', size=11, align='left', bold=True, w=180)
    d.text(0, y + 28, 'pixel value → colour', size=9, align='left', color=MUTED, w=180)
    for k, v in enumerate(CGA):
        x = x0 + k * sw
        d.box(x, y, sw - 4, sh, '<b>%d</b>' % k, rgb565(v), GRID, size=12,
              style='fontColor=%s;' % ('#ffffff' if dark(v) else INK))
        d.text(x + sw / 2 - 2, y + sh + 9, CGA_NAMES[k], size=8, w=sw)
        d.text(x + sw / 2 - 2, y + sh + 21, '0x%04X' % v, size=8, color=MUTED, w=sw, mono=True)
    y = 150
    d.text(0, y - 16, '2 bpp: HW_PALETTE (value 0 = HW_BG)', size=11, align='left', bold=True, w=400)
    for r, (p, idx) in enumerate(PALETTES):
        yy = y + r * 44
        d.text(0, yy + sh / 2, 'HW_PALETTE = %d%s' % (p, '–7' if p == 5 else ''), size=10, align='left', w=180)
        d.box(x0, yy, 2 * sw - 4, sh, '0: HW_BG', '#ffffff', GRID, size=10, style='dashed=1;')
        for k, ci in enumerate(idx):
            x = x0 + (k + 1) * 2 * sw
            d.box(x, yy, 2 * sw - 4, sh, '%d: %s' % (k + 1, CGA_NAMES[ci]), rgb565(CGA[ci]), GRID, size=10,
                  style='fontColor=%s;' % ('#ffffff' if dark(CGA[ci]) else INK))
    y = 430
    d.text(0, y, '1 bpp', size=11, align='left', bold=True, w=180)
    d.text(x0, y, '0 → HW_BG, 1 → HW_FG (both CGA indices; reset: black / white)', size=10, align='left', w=700)
    d.text(0, y + 26, '8 bpp', size=11, align='left', bold=True, w=180)
    d.text(x0, y + 26, 'RGB332 (R[7:5] G[4:2] B[1:0]), widened to RGB565 by bit replication', size=10,
           align='left', w=700)
    d.save('hw_palettes')


def rgb332_ramp():
    d = Drawing()
    sw = 18
    d.text(16 * sw + 20, 12, '8 bpp hardware colours (RGB332): row = upper 3 bits, column = lower 5 bits',
           size=12, bold=True, w=700)
    for v in range(256):
        r3, g3, b2 = (v >> 5) & 7, (v >> 2) & 7, v & 3
        # top-bit replication: R {r, r[2:1]}, G {g, g}, B {b, b, b[1]}
        rgb = ((r3 << 13) | (r3 >> 1) << 11 | (g3 << 8) | g3 << 5 |
               (b2 << 3) | (b2 << 1) | (b2 >> 1))
        d.box(20 + (v & 31) * sw, 30 + (v >> 5) * sw, sw, sw, '', rgb565(rgb), '#ffffff', rounded=False)
    d.save('rgb332_colours')


#=============================================================================
# 8) Frame pointers and FRAME_SEL
#=============================================================================
def frame_pointers():
    d = Drawing()
    d.text(380, 12, 'Frame pointers: one VRAM, up to four frames; FRAME_SEL routes them', size=13, bold=True, w=760)
    vx, vy, vw, vh = 40, 40, 170, 270
    d.box(vx, vy, vw, vh, '', SHADE, GRID, rounded=False)
    d.text(vx + vw / 2, vy + vh + 12, 'VRAM (pixel addresses)', size=10, color=MUTED, w=vw)
    frames = [('frame 0', 0.04, 0.30, FILL), ('frame 1', 0.36, 0.30, YELLOW), ('frame 2<br>(off-screen sprites)', 0.70, 0.22, ROSE)]
    ptr_y = []
    for name, f0, fl, col in frames:
        y = vy + vh * f0
        d.box(vx + 10, y, vw - 20, vh * fl, name, col, INK, size=11)
        ptr_y.append(y)
    for k, (r, f) in enumerate([('FRAME0_PTR', 0), ('FRAME1_PTR', 1), ('FRAME2_PTR', 2), ('FRAME3_PTR', None)]):
        ry = 60 + k * 50
        d.box(290, ry, 120, 30, r, '#ffffff', INK, size=10, style=MONO)
        if f is not None:
            d.line([(290, ry + 15), (vx + vw - 10, ptr_y[f] + 4)], BLUE, 1)
    d.box(450, 50, 60, 200, 'select', SHADE, GRID, size=10)
    for k in range(4):
        d.line([(410, 75 + k * 50), (450, 75 + k * 50)], INK, 1)
    for k, (u, f) in enumerate([('refresh (backend)', 'FRAME_SEL[1:0]')]):
        uy = 70 + k * 70
        d.line([(510, uy + 15), (560, uy + 15)], ACCENT, 1.5)
        d.box(565, uy, 180, 30, u, FILL, INK, size=11)
        d.text(655, uy + 42, f, size=9, color=MUTED, mono=True, w=180)
    d.text(380, 345, 'The GPU and the VRAM window do not use the frame pointers: they use absolute addresses.',
           size=10, color=MUTED, w=760)
    d.save('frame_pointers')


#=============================================================================
# 9) GPU commands at a glance: one panel per drawing command
#=============================================================================
PBG  = '#eaeef2'
PRED = '#cf222e'
PYEL = '#eac54f'
PBLU = '#0969da'
PLBL = '#b6e3ff'
PGRN = '#2da44e'
PDGR = '#116329'
PPUR = '#8250df'
PKEY = '#ff00ff'
GLYPHS = {'A': [' ### ', '#   #', '#   #', '#####', '#   #', '#   #', '#   #'],
          'B': ['#### ', '#   #', '#   #', '#### ', '#   #', '#   #', '#### ']}


def texel(u, v):
    """8 x 8 texture: red top row, yellow left column, blue / light-blue checker."""
    u, v = int(u) % 8, int(v) % 8
    if v == 0:
        return PRED
    if u == 0:
        return PYEL
    return PBLU if ((u // 2) + (v // 2)) % 2 else PLBL


def mix(s, dd, a):
    c = [int(s[k:k + 2], 16) * a + int(dd[k:k + 2], 16) * (1 - a) for k in (1, 3, 5)]
    return '#%02x%02x%02x' % tuple(int(round(x)) for x in c)


def inside_tri(px, py, v):
    def e(a, bb):
        return (bb[0] - a[0]) * (py - a[1]) - (bb[1] - a[1]) * (px - a[0])
    w = [e(v[0], v[1]), e(v[1], v[2]), e(v[2], v[0])]
    return all(x >= 0 for x in w) or all(x <= 0 for x in w)


def bary(px, py, v):
    (x0, y0), (x1, y1), (x2, y2) = v
    den = (y1 - y2) * (x0 - x2) + (x2 - x1) * (y0 - y2)
    l0 = ((y1 - y2) * (px - x2) + (x2 - x1) * (py - y2)) / den
    l1 = ((y2 - y0) * (px - x2) + (x0 - x2) * (py - y2)) / den
    return l0, l1, 1 - l0 - l1


def pgrid(d, x, y, w, h, c, f):
    """A w x h pixel grid at (x, y), cell c; f(i, j) gives a colour or None (background)."""
    for j in range(h):
        for i in range(w):
            col = f(i, j) or PBG
            d.box(x + i * c, y + j * c, c, c, '', col, '#ffffff', rounded=False)


def tex_grid(d, x, y, c=10):
    pgrid(d, x, y, 8, 8, c, texel)
    d.text(x + 4 * c, y + 8 * c + 10, 'texture', size=9, color=MUTED, w=8 * c + 20)


def gpu_commands():
    d = Drawing()
    PW, PH, C = 340, 268, 11
    d.text(2 * PW, 12, 'GPU commands at a glance', size=15, bold=True, w=900)
    d.text(2 * PW, 34, 'SET_ commands load settings (surfaces, size, colours, texture) that stay until '
           'changed; each EXEC_ command draws one primitive with the current settings', size=10,
           color=MUTED, w=1100)
    panels = []

    def panel(k, title, sub, caption):
        x, y = (k % 4) * PW, 56 + (k // 4) * PH
        d.box(x + 4, y, PW - 8, PH - 10, '', '#ffffff', '#d0d7de', style='arcSize=4;')
        d.text(x + PW / 2, y + 16, title, size=12, bold=True, color=BLUE, mono=True, w=PW - 20)
        d.text(x + PW / 2, y + 33, sub, size=9, color=MUTED, w=PW - 20)
        d.text(x + PW / 2, y + PH - 38, caption, size=9, w=PW - 30, h=36)
        return x, y

    def arrow(x0, y0, x1):
        d.line([(x0, y0), (x1, y0)], INK, 1.5)

    # --- row 1: fills -------------------------------------------------------
    x, y = panel(0, 'EXEC_FILL', 'SET_DST · SET_SIZE · SET_FILL',
                 'Fills the W × H rectangle at the destination base with the fill colour '
                 '(or a raster op of it with what is there).')
    gx, gy = x + (PW - 16 * C) / 2, y + 62
    pgrid(d, gx, gy, 16, 12, C, lambda i, j: PPUR if 3 <= i <= 12 and 3 <= j <= 9 else None)
    d.dot(gx + 3.5 * C, gy + 3.5 * C, 4)
    d.text(gx + 8 * C, gy + 1.5 * C, 'W', size=10, bold=True, w=20)
    d.text(gx + 1.5 * C, gy + 6.5 * C, 'H', size=10, bold=True, w=20)
    d.text(gx - 4, gy + 3.5 * C, 'base', size=9, color=MUTED, align='right', w=40)

    x, y = panel(1, 'EXEC_SPAN', 'one command word per run',
                 'Moves the base by DELTA, then draws a run of WIDTH pixels: run-length images '
                 'and round shapes, one word per run.')
    gx, gy = x + (PW - 16 * C) / 2, y + 62
    runs = []
    for j in range(1, 11):
        dy = j + 0.5 - 6
        if abs(dy) < 5.2:
            hw = (5.2 ** 2 - dy * dy) ** 0.5
            runs.append((j, int(round(7.5 - hw + 0.5)), int(round(7.5 + hw - 0.5))))
    rowc = {j: (PGRN if n % 2 == 0 else PDGR) for n, (j, a, z) in enumerate(runs)}
    pgrid(d, gx, gy, 16, 12, C,
          lambda i, j: next((rowc[r] for r, a, z in runs if r == j and a <= i <= z), None))
    for n, (j, a, z) in enumerate(runs):
        d.dot(gx + (a + 0.5) * C, gy + (j + 0.5) * C, 2.5, '#ffffff')
    d.text(gx + 8 * C, gy + 12 * C + 12, '○ run start: the previous one + DELTA', size=9, color=MUTED, w=220)

    x, y = panel(2, 'SET_GRAD + EXEC_FILL', 'gradient fill',
                 'Writes fill + ⌊line / N⌋ · STEP: with a palette ramp, a sky or a bar in one command '
                 '(lines or pixels along the run).')
    ramp = ['#0a3069', '#0550ae', '#0969da', '#218bff', '#54aeff', '#80ccff']
    gx, gy = x + (PW - 16 * C) / 2, y + 62
    pgrid(d, gx, gy, 16, 12, C, lambda i, j: ramp[(j - 1) // 2] if 1 <= i <= 14 and 1 <= j <= 10 else None)
    d.text(gx + 16 * C + 4, gy + 2 * C, 'N = 2', size=9, color=MUTED, align='left', w=40)

    x, y = panel(3, 'EXEC_FILL  TRI', 'SET_V0 · SET_V1 · SET_V2',
                 'Draws the pixels whose centre lies inside the triangle; the top-left rule on the '
                 'edges leaves no gap and no overlap between neighbours.')
    gx, gy = x + (PW - 16 * C) / 2, y + 62
    tv = [(1.3, 1.0), (14.6, 4.2), (5.0, 11.4)]
    pgrid(d, gx, gy, 16, 12, C, lambda i, j: PPUR if inside_tri(i + 0.5, j + 0.5, tv) else None)
    pts = [(gx + a * C, gy + bb * C) for a, bb in tv]
    d.line(pts + [pts[0]], INK, 1.5, arrow=False)
    for n, (p, (ox, oy)) in enumerate(zip(pts, [(-12, -8), (14, -8), (-12, 8)])):
        d.dot(p[0], p[1], 3.5)
        d.text(p[0] + ox, p[1] + oy, 'V%d' % n, size=9, bold=True, w=20)

    # --- row 2: copies --------------------------------------------------------
    x, y = panel(4, 'EXEC_COPY', 'SET_SRC · SET_DST · SET_SIZE · swaps',
                 'Copies a rectangle of pixels; the swaps of the source and destination walks '
                 'mirror or rotate it on the way.')
    sx, sy = x + 20, y + 80
    tex_grid(d, sx, sy)
    arrow(sx + 88, sy + 40, sx + 112)
    gx, gy = x + 140, y + 70
    pgrid(d, gx, gy, 18, 10, 10, lambda i, j: (texel(i - 0, j - 1) if 0 <= i <= 7 and 1 <= j <= 8 else
                                              texel(17 - i, j - 1) if 10 <= i <= 17 and 1 <= j <= 8 else None))
    d.text(gx + 40, gy + 110, 'no swap', size=9, color=MUTED, w=70)
    d.text(gx + 140, gy + 110, 'X swap', size=9, color=MUTED, w=70)

    x, y = panel(5, 'EXEC_COPY_TRANSP', 'SET_TRANSP = magenta',
                 'Like COPY, but source pixels equal to the transparent colour are skipped: sprites '
                 'over a background.')

    def sprite(i, j):
        r = ((i - 3.5) ** 2 + (j - 3.5) ** 2) ** 0.5
        if r > 3.6:
            return PKEY
        return PYEL if (i - 2.5) ** 2 + (j - 2.5) ** 2 < 1.6 else PGRN
    sx, sy = x + 20, y + 80
    pgrid(d, sx, sy, 8, 8, 10, sprite)
    d.text(sx + 40, sy + 90, 'sprite', size=9, color=MUTED, w=60)
    arrow(sx + 88, sy + 40, sx + 112)
    gx, gy = x + 150, y + 70
    bgp = lambda i, j: PLBL if (i + j) % 4 < 2 else None
    pgrid(d, gx, gy, 15, 12, 11, lambda i, j: (sprite(i - 4, j - 2) if 4 <= i <= 11 and 2 <= j <= 9
                                              and sprite(i - 4, j - 2) != PKEY else bgp(i, j)))

    x, y = panel(6, 'EXEC_EXPAND', 'SET_SRC = 1-bit glyph · DELTA = advance',
                 'Turns a 1, 2, 4 or 8-bit image into colours: 1 → fill colour, 0 → skipped (or the '
                 'background). Text: one word per character.')
    sx, sy = x + 16, y + 92
    gl = lambda i, j: (INK if (GLYPHS['A' if i < 5 else 'B'][j][i % 5] == '#') else '#ffffff') if j < 7 else None
    pgrid(d, sx, sy, 10, 7, 9, gl)
    d.text(sx + 45, sy + 74, 'font (1 bit)', size=9, color=MUTED, w=80)
    arrow(sx + 96, sy + 32, sx + 118)
    gx, gy = x + 148, y + 70

    def ex(i, j):
        for ch, ox in (('A', 1), ('B', 8)):
            if ox <= i < ox + 5 and 2 <= j < 9 and GLYPHS[ch][j - 2][i - ox] == '#':
                return PPUR
        return bgp(i, j)
    pgrid(d, gx, gy, 15, 11, 11, ex)
    d.line([(gx + 1.5 * C, gy + 1 * C), (gx + 8.5 * C, gy + 1 * C)], INK, 1)
    d.text(gx + 5 * C, gy + 0.5 * C - 6, 'DELTA', size=8, w=40)

    x, y = panel(7, 'SET_ALPHA', 'blending (16 bpp), any EXEC',
                 'Mixes what is drawn with the destination: out = d + (s − d) · α. Translucent '
                 'windows, shadows, anti-aliased text (EXPAND MASK).')
    gx, gy = x + (PW - 16 * C) / 2, y + 62

    def bl(i, j):
        base = '#d0d7de' if (i // 2 + j // 2) % 2 else None
        if 1 <= i <= 8 and 1 <= j <= 7:
            base = PBLU
        if 5 <= i <= 14 and 4 <= j <= 10:
            return mix(PRED, base or PBG, 0.5)
        return base
    pgrid(d, gx, gy, 16, 12, C, bl)
    d.text(gx + 16 * C + 4, gy + 10 * C, 'α = ½', size=9, color=MUTED, align='left', w=40)

    # --- row 3: textures and lists ---------------------------------------------
    x, y = panel(8, 'EXEC_TEXSPAN', 'SET_TEX · SET_UV · SET_STEP',
                 'Draws a run of N pixels stepping (u, v) through a texture; here one vertical run '
                 'per command, each scaled: a raycaster wall.')
    sx, sy = x + 20, y + 80
    tex_grid(d, sx, sy)
    arrow(sx + 88, sy + 40, sx + 112)
    gx, gy = x + 150, y + 64

    def wall(i, j):
        hh = 12 - i * 0.55
        top = (12 - hh) / 2
        if top <= j + 0.5 < top + hh:
            return texel(i, (j + 0.5 - top) * 8 / hh)
        return None
    pgrid(d, gx, gy, 14, 12, C, wall)

    x, y = panel(9, 'EXEC_TEXRECT', 'SET_STEP · SET_STEP_ROW · SET_TEXBOX',
                 'Fills the rectangle from the texture with per-pixel and per-row steps: rotated and '
                 'scaled images; BOUND skips what falls outside.')
    sx, sy = x + 20, y + 80
    tex_grid(d, sx, sy)
    arrow(sx + 88, sy + 40, sx + 112)
    gx, gy = x + 150, y + 64
    import math
    ca, sa, kk = math.cos(math.radians(30)), math.sin(math.radians(30)), 1.25

    def rot(i, j):
        dx, dy = i + 0.5 - 7, j + 0.5 - 6
        u, v = 4 + (dx * ca - dy * sa) / kk, 4 + (dx * sa + dy * ca) / kk
        return texel(u, v) if 0 <= u < 8 and 0 <= v < 8 else None
    pgrid(d, gx, gy, 14, 12, C, rot)

    x, y = panel(10, 'EXEC_TEXRECT  TRI', 'SET_V0..V2 · (u, v) at V0 · gradients',
                 'Maps the texture on the triangle (affine): (u, v) at V0 plus its steps per pixel and '
                 'per row, computed once by the driver.')
    sx, sy = x + 20, y + 80
    tex_grid(d, sx, sy)
    arrow(sx + 88, sy + 40, sx + 112)
    gx, gy = x + 150, y + 64
    tv = [(0.4, 0.4), (13.6, 2.0), (2.5, 11.6)]
    uv = [(0, 0), (8, 0), (0, 8)]

    def ttri(i, j):
        if not inside_tri(i + 0.5, j + 0.5, tv):
            return None
        l0, l1, l2 = bary(i + 0.5, j + 0.5, tv)
        return texel(min(7.99, max(0, l0 * uv[0][0] + l1 * uv[1][0] + l2 * uv[2][0])),
                     min(7.99, max(0, l0 * uv[0][1] + l1 * uv[1][1] + l2 * uv[2][1])))
    pgrid(d, gx, gy, 14, 12, C, ttri)
    pts = [(gx + a * C, gy + bb * C) for a, bb in tv]
    d.line(pts + [pts[0]], INK, 1.5, arrow=False)

    x, y = panel(11, 'CALL · FENCE', 'command lists and synchronisation',
                 'CALL runs N words stored in VRAM (a list written once, replayed each frame); FENCE '
                 'marks a point in the stream: GPU_FENCE, optional IRQ.')
    words = ['SET_DST', 'SET_SIZE', 'EXEC_FILL', 'CALL  N', 'FENCE  IRQ']
    fx, fy = x + 30, y + 64
    d.text(fx + 50, fy - 4, 'GPU_CMD (FIFO)', size=9, bold=True, color=MUTED, w=110)
    for n, wd in enumerate(words):
        d.box(fx, fy + 8 + n * 26, 100, 22, wd, YELLOW if n == 3 else (ROSE if n == 4 else FILL), INK,
              size=9, style=MONO, rounded=False)
    lx, ly = x + 200, y + 64
    d.text(lx + 50, ly - 4, 'list in VRAM', size=9, bold=True, color=MUTED, w=110)
    for n, wd in enumerate(['SET_SRC', 'EXEC_COPY', 'SET_DST', 'EXEC_COPY', '…']):
        d.box(lx, ly + 8 + n * 22, 100, 18, wd, '#ffffff', GRID, size=9, style=MONO, rounded=False)
    d.line([(fx + 100, fy + 8 + 3 * 26 + 11), (lx - 20, fy + 8 + 3 * 26 + 11), (lx - 20, ly + 17), (lx, ly + 17)],
           INK, 1.2)
    d.line([(lx + 50, ly + 8 + 5 * 22 - 4), (lx + 50, fy + 8 + 4 * 26 + 11), (fx + 100, fy + 8 + 4 * 26 + 11)],
           GRID, 1.2, dashed=True)
    d.text(lx + 56, ly + 8 + 5 * 22 + 6, 'then back', size=8, color=MUTED, align='left', w=60)
    d.save('gpu_commands')


if __name__ == '__main__':
    block()
    soc()
    gpu_pipeline()
    bpp_packing()
    disp_cfg_matrix()
    rect_walks()
    palettes()
    rgb332_ramp()
    frame_pointers()
    gpu_commands()
