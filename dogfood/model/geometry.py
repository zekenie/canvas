#!/usr/bin/env python3
"""The geometry the layout uses (boxes, arcs, offsets from a shape's sides: `right of "A" left (gap: x)
below "A" top (gap: y)`), the sizes of what it draws, and measuring.
    geometry.py measure M...          note heights at their widths, on a scratch subboard
    geometry.py about-pad M...        each About note's height, with room for its mentions' symbols"""
import json, math, os, re, sys
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import common
from common import q, text_lit, ftitle, board_files, file_text, about_text, about_title, PROD, MODS, BANDS, FOLDER_BOARDS, draw, cli

NOTE_W, ABOUT_W = 300, 360
SUB_W, SUB_H = 360, 180
PILL_H, PILL_STEP, PILL_GAP = 32, 16, 80   # a pill; draw's step between the pills beside a start, and its gap from it
PILL_PITCH = PILL_H + PILL_STEP
FRAME_MIN_H = 64                            # the smallest frame draw makes (96 wide), as the Frame tool
MEASURED = os.path.join(common.PROJECT, 'measured.json')

def pill_w(title):
    return min(280, 70 + 7.6 * len(title))

# ---- geometry ----------------------------------------------------------------------------------

class Box:
    def __init__(self, x, y, w, h, name=''):
        self.x, self.y, self.w, self.h, self.name = x, y, w, h, name
    @property
    def c(self): return (self.x + self.w / 2, self.y + self.h / 2)
    def inflate(self, d): return Box(self.x - d, self.y - d, self.w + 2 * d, self.h + 2 * d, self.name)
    def contains(self, p): return self.x <= p[0] <= self.x + self.w and self.y <= p[1] <= self.y + self.h
    def overlaps(self, o): return self.x < o.x + o.w and o.x < self.x + self.w and self.y < o.y + o.h and o.y < self.y + self.h

def arc_points(a, b, bend, n=48):
    """Points along the arrow from center a to center b, bent as Connections bends it: through the
    midpoint pushed `bend` along the chord turned a quarter toward +y."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    L = math.hypot(dx, dy) or 1
    perp = (-dy / L, dx / L)
    m = ((a[0] + b[0]) / 2 + perp[0] * bend, (a[1] + b[1]) / 2 + perp[1] * bend)
    if abs(bend) < 1:
        return [(a[0] + dx * t / n, a[1] + dy * t / n) for t in range(n + 1)]
    # the circle through a, m, b
    ax, ay, bx, by, cx, cy = a[0], a[1], m[0], m[1], b[0], b[1]
    d = 2 * (ax * (by - cy) + bx * (cy - ay) + cx * (ay - by))
    ux = ((ax * ax + ay * ay) * (by - cy) + (bx * bx + by * by) * (cy - ay) + (cx * cx + cy * cy) * (ay - by)) / d
    uy = ((ax * ax + ay * ay) * (cx - bx) + (bx * bx + by * by) * (ax - cx) + (cx * cx + cy * cy) * (bx - ax)) / d
    r = math.hypot(ax - ux, ay - uy)
    t0, tm, t1 = math.atan2(ay - uy, ax - ux), math.atan2(m[1] - uy, m[0] - ux), math.atan2(cy - uy, cx - ux)
    def norm(t): return t % (2 * math.pi)
    sweep = norm(t1 - t0)
    if norm(tm - t0) > sweep:
        sweep -= 2 * math.pi
    return [(ux + r * math.cos(t0 + sweep * i / n), uy + r * math.sin(t0 + sweep * i / n)) for i in range(n + 1)]

# ---- placing ------------------------------------------------------------------------------------

def at(anchor, x, y):
    """Offsets from the top-left of `anchor` (a frame, or the board's first note)."""
    return f"right of {q(anchor)} left (gap: {round(x)}) below {q(anchor)} top (gap: {round(y)})"

def note_w(title, public):
    """A title pill is about 27 + 10.2 a character; a compact Public chip with its count, 75 more."""
    need = 27 + 10.2 * len(title) + (8 + 75 if public else 0) + 16
    return max(NOTE_W, int(math.ceil(need / 20) * 20))

def list_h(n):
    return PILL_PITCH * n - (PILL_PITCH - PILL_H) if n else 0

# ---- the root's bands ----------------------------------------------------------------------------

def band_order():
    """Each band's modules ordered so arrows run short: by the mean position of what they import and
    what imports them, a few sweeps up and down."""
    order = {t: list(ms) for t, ms in BANDS}
    pos = {}
    def refresh():
        for t, ms in order.items():
            for i, m in enumerate(ms):
                pos[m] = (i + 0.5) / len(ms)
    refresh()
    for _ in range(6):
        for t, ms in order.items():
            def key(m):
                near = MODS[m]['deps'] + [u for u in PROD if m in MODS[u]['deps']]
                near = [pos[n] for n in near if n in pos]
                return sum(near) / len(near) if near else pos[m]
            order[t] = sorted(ms, key=key)
        refresh()
    return [(t, order[t]) for t, _ in BANDS]

# ---- measuring ----------------------------------------------------------------------------------

def measured():
    return json.load(open(MEASURED)) if os.path.exists(MEASURED) else {}

def step_measure(mods):
    """Each note's height at its width: drawn on a scratch subboard at that width, then given its
    text (a note's size lasts until its text changes, and it then fits its text), then deleted. What a
    note mentions that isn't drawn yet stands in on the scratch subboard meanwhile."""
    notes = []
    _, other_all = common.edges_between(set(PROD))
    def file_note(k):
        return (ftitle(k), note_w(ftitle(k), common.is_public(k, other_all)), file_text(k))
    for m in mods:      # a module with folder boards: its own board's About note and files
        if m in FOLDER_BOARDS:
            notes.append((about_title(m), ABOUT_W, about_text(m)))
            notes += [file_note(k) for k in board_files(m)]
    for board in common.boards_for(mods):
        notes.append((about_title(board), ABOUT_W, about_text(board)))
        notes += [file_note(k) for k in board_files(board)]
    if not notes:
        raise SystemExit('name the modules to measure')
    scratch = 'zz-measure'
    cli(f'delete {q(scratch)}\n', dry=False)
    draw('measure-0', f'subboard {q(scratch)} right of board\n')     # clear of what's drawn
    first = 'zz:' + notes[0][0]
    lines = [f"sticky-note {q(first)} in {q(scratch)} size: {notes[0][1]}x200 text: \"x\""]
    lines += [f"sticky-note {q('zz:' + t)} in {q(scratch)} below {q(first)} size: {w}x200 text: \"x\"" for t, w, _ in notes[1:]]
    found = common.canvas('query', '--board', common.BOARD, '--limit', '10000', '[title]')
    if found['count'] > len(found['rows']):
        raise SystemExit(f"measure: {found['count']} titled shapes, more than a query lists")
    mentioned = set(re.findall(r'@\[([^\]]+)\]', ''.join(tx for _, _, tx in notes)))
    lines += [f"sticky-note {q(t)} in {q(scratch)} below {q(first)}" for t in sorted(mentioned - {r['title'] for r in found['rows']})]
    draw('measure-1', '\n'.join(lines) + '\n')
    rc, r = cli('\n'.join(f"sticky-note {q('zz:' + t)} text: {text_lit(tx)}" for t, w, tx in notes) + '\n', dry=False)   # overlaps don't matter here
    if 'error' in r:
        raise SystemExit(f"measuring refused: {r['error']}")
    M = measured()
    for c in r['changes']:
        if c.get('kind') == 'sticky-note' and c.get('title', '').startswith('zz:'):
            M[c['title'][3:]] = c['at'][1][1]
    json.dump(M, open(MEASURED, 'w'), indent=1)
    draw('measure-3', f'delete {q(scratch)}\n')
    print(f"measured {len(notes)} notes; tallest {max(M[t] for t, _, _ in notes)}")

def about_height(board, M):
    """An About note's height: as measured, its mention pills and all."""
    return math.ceil(M[about_title(board)])

def step_about_pad(mods):
    M = measured()
    boards = common.boards_for(mods) + [m for m in mods if m in FOLDER_BOARDS]
    for board in boards:
        draw(f'about-{board.replace("/", "_")}', f"sticky-note {q(about_title(board))} size: {ABOUT_W}x{about_height(board, M)}\n")

if __name__ == '__main__':
    step, args = sys.argv[1], sys.argv[2:]
    dict(measure=step_measure, **{'about-pad': step_about_pad})[step](args)
