#!/usr/bin/env python3
"""The geometry the layouts share (boxes, arcs, offsets from a shape's sides: `right of "A" left (gap: x)
below "A" top (gap: y)`), and measuring. The second layout's steps are still here; gen5.py is the one drawn.
    gen2.py measure M...              note heights at their widths, on a scratch subboard
    gen2.py about-pad M...            each About note's height, with room for its mentions' symbols"""
import json, math, os, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen
from gen import q, text_lit, ftitle, board_of, board_files, key_in, file_text, about_text, about_title, PROD, MODS, FILES, model, draw, cli, RUNS
from spec import BANDS, CANVAS_FOLDERS, GROUPS, BY_MODULE

NOTE_W, ABOUT_W, LEGEND_W = 300, 360, 560
SUB_W, SUB_H = 360, 180
P = 48                      # inside a frame, from each edge (`in` needs 40)
GX, GY = 80, 96             # between units
BGX, BGY = 160, 200         # between blocks on a board
SUB = 96                    # above a frame's subframes
PILL_H, PILL_PITCH, PILL_GAP = 32, 96, 80
MEASURED = os.path.join(HERE, 'measured2.json')

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

def hits(points, obstacles):
    return sum(1 for o in obstacles if any(o.contains(p) for p in points))

def choose_bend(a_box, b_box, obstacles, frac=0.2, cap=320):
    """The smallest bend, up to `frac` of the arrow's length and `cap`, that takes it clear of the
    shapes it would cross; straight when no bend that small clears more of them."""
    a, b = a_box.c, b_box.c
    others = [o.inflate(10) for o in obstacles if o is not a_box and o is not b_box]
    L = math.hypot(b[0] - a[0], b[1] - a[1])
    straight = hits(arc_points(a, b, 0), others)
    if straight == 0:
        return 0
    best, best_h = 0, straight
    for f in (0.06, 0.1, 0.14, 0.2, 0.26, 0.32):
        if f > frac: break
        mag = min(cap, max(40, f * L))
        for sign in (1, -1):
            h = hits(arc_points(a, b, sign * mag), others)
            if h < best_h:
                best, best_h = round(sign * mag), h
        if best_h == 0:
            break
    return best

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

class Unit:
    """A note, its pills on the right (`pills`) and, for a file that points at modules, on the left too."""
    def __init__(self, title, text, w, h, pills, public, key=None, left=()):
        self.title, self.text, self.w, self.nh, self.public, self.key = title, text, w, h, public, key
        self.pills, self.left = list(pills), list(left)
        self.k = len(self.pills)
        self.pw = max((pill_w(p) for p in self.pills), default=0)
        self.pwl = max((pill_w(p) for p in self.left), default=0)
        self.L, self.LL = list_h(len(self.pills)), list_h(len(self.left))
        self.lx = (self.pwl + PILL_GAP) if self.left else 0
        self.uw = self.lx + w + (PILL_GAP + self.pw if self.k else 0)
        self.uh = max(h, self.L, self.LL)

def cols_for(n):
    return n if n <= 3 else 2 if n == 4 else 3 if n <= 9 else 4

class Grid:
    """Units in columns and rows; each row's notes share a middle, each unit's pills centered on its note."""
    def __init__(self, units, cols=None):
        self.units = units
        n = len(units)
        self.C = min(cols or cols_for(n), n) if n else 0
        self.R = math.ceil(n / self.C) if n else 0
        self.cw = [max(u.uw for i, u in enumerate(units) if i % self.C == c) for c in range(self.C)]
        self.rh = [max(u.uh for i, u in enumerate(units) if i // self.C == r) for r in range(self.R)]
        self.w = sum(self.cw) + GX * (self.C - 1) if n else 0
        self.h = sum(self.rh) + GY * (self.R - 1) if n else 0

    def place(self, x0, y0):
        """Each unit's note's top-left, and its pills' boxes."""
        out = []
        for i, u in enumerate(self.units):
            r, c = divmod(i, self.C)
            x = x0 + sum(self.cw[:c]) + GX * c + u.lx
            mid = y0 + sum(self.rh[:r]) + GY * r + self.rh[r] / 2
            y = mid - u.nh / 2
            pills = [Box(x + u.w + PILL_GAP, mid - u.L / 2 + j * PILL_PITCH, pill_w(p), PILL_H, p) for j, p in enumerate(u.pills)]
            pills += [Box(x - PILL_GAP - pill_w(p), mid - u.LL / 2 + j * PILL_PITCH, pill_w(p), PILL_H, p) for j, p in enumerate(u.left)]
            out.append((u, x, y, pills))
        return out

class Frame:
    def __init__(self, title, units, subs):
        self.title, self.grid, self.subs = title, Grid(units), subs
        sw = sum(s.w for s in subs) + GX * (len(subs) - 1) if subs else 0
        sh = max((s.h for s in subs), default=0)
        self.inner_w = max(self.grid.w, sw)
        self.w = math.ceil(2 * P + self.inner_w)
        self.h = math.ceil(2 * P + self.grid.h + (SUB if units and subs else 0) + sh)


def layout_frame(fr, bx, by, parent, frames, notes):
    """Lays out frame `fr` with its top-left at board (bx, by); `parent` is what it's placed in."""
    frames.append(dict(title=fr.title, parent=parent, bx=bx, by=by, w=fr.w, h=fr.h))
    for (u, x, y, pills) in fr.grid.place(bx + P, by + P):
        notes.append(dict(unit=u, holder=fr.title, hx=bx, hy=by, x=x, y=y, pills=pills))
    sx = bx + P
    sy = by + P + fr.grid.h + (SUB if fr.grid.units else 0)
    for s in fr.subs:
        layout_frame(s, sx, sy, fr.title, frames, notes)
        sx += s.w + GX

def shelf(blocks, start_x, target_w, first_row_h):
    """Rows of blocks (objects with .w, .h), the first starting at start_x beside something
    first_row_h tall at the left: returns [(block, x, y)], rows top-aligned."""
    out, x, y, row_h = [], start_x, 0, first_row_h
    for b in blocks:
        if x > (start_x if y == 0 else 0) and x + b.w > target_w:
            x, y, row_h = 0, y + row_h + BGY, 0
        out.append((b, x, y))
        x += b.w + BGX
        row_h = max(row_h, b.h)
    return out

# ---- the model's boards -------------------------------------------------------------------------

def measured():
    return json.load(open(MEASURED)) if os.path.exists(MEASURED) else {}

def plan_board(board, drawn):
    """Everything on a module's (or folder's) board: the About note, frames, notes and pills, in board
    coordinates with the About note's top-left at (0, 0)."""
    M = measured()
    same, other = gen.edges_between(drawn)
    _, other_all = gen.edges_between(set(PROD))
    def unit(k):
        t = ftitle(k)
        pub = gen.is_public(k, other_all)
        right, left = pill_targets(k, other)
        return Unit(t, file_text(k), note_w(t, pub), M[t], right, pub, key=k, left=left)
    about = Unit(about_title(board), about_text(board), ABOUT_W, M[about_title(board)], [], False)
    frames, notes = [], []
    spec = GROUPS.get(board)
    if spec:
        def build(g):
            title, names, subs = g
            return Frame(title, [unit(key_in(board, n)) for n in names], [build(s) for s in subs])
        tops = [build(g) for g in spec]
        listed = [u.key for f in tops for u in walk_units(f)]
        missing = set(board_files(board)) - set(listed)
        if missing:
            raise SystemExit(f"{board}: the spec leaves out {sorted(ftitle(k) for k in missing)}")
        area = sum(f.w * f.h for f in tops) + ABOUT_W * about.nh
        target = max(max(f.w for f in tops) + ABOUT_W + BGX, math.sqrt(area * 1.7))
        for f, x, y in shelf(tops, ABOUT_W + BGX, target, about.nh):
            layout_frame(f, x, y, None, frames, notes)
    else:
        grid = Grid([unit(k) for k in board_files(board)])
        for (u, x, y, pills) in grid.place(ABOUT_W + BGX, 0):
            notes.append(dict(unit=u, holder=None, x=x, y=y, pills=pills))
    return about, frames, notes, same, other

def pill_targets(k, other):
    """The titles a file's pills stand for, right and left: the files it uses on other boards, or, for a
    file in BY_MODULE, the modules it uses, half on each side."""
    if k in BY_MODULE:
        mods = sorted(set(t[0] for t in other.get(k, []) if t[0] != k[0]))
        half = (len(mods) + 1) // 2
        return mods[:half], mods[half:]
    return [ftitle(x) for x in other.get(k, [])], []

def walk_units(f):
    yield from f.grid.units
    for s in f.subs:
        yield from walk_units(s)

def obstacles_of(about, notes, pills=True):
    obs = [Box(0, 0, ABOUT_W, about.nh, about.title)]
    by_title = {}
    for n in notes:
        b = Box(n['x'], n['y'], n['unit'].w, n['unit'].nh, n['unit'].title)
        obs.append(b); by_title[n['unit'].title] = b
        if pills: obs += n['pills']
    return obs, by_title

def check_pills(about, frames, notes):
    """Every predicted pill clear of every note and other pill, and inside its note's frame."""
    obs, _ = obstacles_of(about, notes)
    boxes = [o for o in obs]
    problems = []
    for i, a in enumerate(boxes):
        for b in boxes[i + 1:]:
            if a.overlaps(b):
                problems.append(f"{a.name} overlaps {b.name}")
    fr = {f['title']: f for f in frames}
    for n in notes:
        if n['holder']:
            f = fr[n['holder']]
            for p in n['pills'] + [Box(n['x'], n['y'], n['unit'].w, n['unit'].nh)]:
                if p.x < f['bx'] + 40 or p.y < f['by'] + 40 or p.x + p.w > f['bx'] + f['w'] - 40 or p.y + p.h > f['by'] + f['h'] - 40:
                    problems.append(f"{p.name or n['unit'].title} pokes out of {f['title']}")
    return problems

def note_stmt(u, place, holder):
    parts = [f"sticky-note {q(u.title)}"] + ([f"in {q(holder)}"] if holder else []) + [place, f"size: {u.w}x{math.ceil(u.nh)}"]
    if u.public: parts.append("public: true")
    parts.append(f"text: {text_lit(u.text)}")
    return ' '.join(parts)

def step_boards(mods):
    drawn = set(gen.drawn_modules()) | set(mods)
    for board in gen.boards_for(mods):
        about, frames, notes, _, _ = plan_board(board, drawn)
        problems = check_pills(about, frames, notes)
        if problems:
            print(f"{board}: the plan has overlaps:\n  " + '\n  '.join(problems[:20])); sys.exit(1)
        label = board.replace('/', '_')
        A = about.title
        lines = [f"sticky-note {q(A)} in {q(board)} size: {ABOUT_W}x{math.ceil(about.nh)} text: {text_lit(about.text)}"]
        for f in frames:
            if f['parent'] is None:
                lines.append(f"frame {q(f['title'])} in {q(board)} size: {f['w']}x{f['h']} {at(A, f['bx'], f['by'])}")
        if not frames:
            for n in notes:
                lines.append(note_stmt(n['unit'], at(A, n['x'], n['y']), board))
            draw(f'v2-board-{label}-notes', '\n'.join(lines) + '\n')
            continue
        draw(f'v2-board-{label}-frames', '\n'.join(lines) + '\n')
        # nested frames, a level at a time
        level = {f['title']: 0 for f in frames if f['parent'] is None}
        pending = [f for f in frames if f['parent'] is not None]
        fr = {f['title']: f for f in frames}
        depth = 1
        while pending:
            now = [f for f in pending if f['parent'] in level and level[f['parent']] == depth - 1]
            lines = [f"frame {q(f['title'])} in {q(f['parent'])} size: {f['w']}x{f['h']} "
                     f"{at(f['parent'], f['bx'] - fr[f['parent']]['bx'], f['by'] - fr[f['parent']]['by'])}" for f in now]
            draw(f'v2-board-{label}-frames-{depth + 1}', '\n'.join(lines) + '\n')
            for f in now: level[f['title']] = depth
            pending = [f for f in pending if f not in now]
            depth += 1
        lines = [note_stmt(n['unit'], at(n['holder'], n['x'] - n['hx'], n['y'] - n['hy']), n['holder']) for n in notes]
        draw(f'v2-board-{label}-notes', '\n'.join(lines) + '\n')
    for m in mods:
        open(os.path.join(RUNS, f'drawn-{m}'), 'w').write('')

def step_edges(mods):
    drawn = set(gen.drawn_modules())
    for board in gen.boards_for(mods) + (['Canvas'] if 'Canvas' in mods else []):
        if board == 'Canvas':
            about, notes = None, []
        lines = []
        if board != 'Canvas':
            about, frames, notes, same, other = plan_board(board, drawn)
            obs, by_title = obstacles_of(about, notes, pills=False)
        else:
            same, other = gen.edges_between(drawn)
            obs, by_title = [], {}
        keys = board_files(board)
        for k in keys:
            right, left = pill_targets(k, other)
            lines += [f"edge {q(ftitle(k))} -> {q(t)}" for t in right]
            lines += [f"edge {q(ftitle(k))} -> {q(t)} from: left" for t in left]
        done = set()
        for k in keys:
            for t in sorted(set(same.get(k, [])), key=ftitle):
                if (k, t) in done: continue
                both = k in same.get(t, [])
                done |= {(k, t), (t, k)} if both else {(k, t)}
                a, b = by_title.get(ftitle(k)), by_title.get(ftitle(t))
                bend = choose_bend(a, b, obs) if a and b else 0
                arrow = '<->' if both else '->'
                lines.append(f"edge {q(ftitle(k))} {arrow} {q(ftitle(t))}" + (f" bend: {bend}" if bend else ''))
        if lines:
            draw(f'v2-edges-{board.replace("/", "_")}', '\n'.join(lines) + '\n')

# ---- root and Canvas ------------------------------------------------------------------------------

LEGEND = gen.LEGEND

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

def step_root():
    M = measured()
    legend_h = M.get(LEGEND, 520)
    bands = band_order()
    rows = []
    for title, mods in bands:
        C = min(len(mods), 7)
        R = math.ceil(len(mods) / C)
        w = 2 * P + C * SUB_W + (C - 1) * BGX
        h = 2 * P + R * SUB_H + (R - 1) * BGX
        rows.append((title, mods, C, R, w, h))
    maxw = max(r[4] for r in rows)
    x0 = LEGEND_W + BGX
    lines = [f"sticky-note {q(LEGEND)} size: {LEGEND_W}x{math.ceil(legend_h)} text: {text_lit(gen.LEGEND_TEXT)}"]
    y = 0
    boxes, band_box = {}, {}
    for title, mods, C, R, w, h in rows:
        bx = x0 + (maxw - w) / 2
        lines.append(f"frame {q(title)} size: {w}x{h} {at(LEGEND, bx, y)}")
        band_box[title] = (bx, y)
        for i, m in enumerate(mods):
            r, c = divmod(i, C)
            in_row = min(C, len(mods) - r * C)
            row_w = in_row * SUB_W + (in_row - 1) * BGX
            sx = bx + (w - row_w) / 2 + c * (SUB_W + BGX)
            sy = y + P + r * (SUB_H + BGX)
            boxes[m] = Box(sx, sy, SUB_W, SUB_H, m)
        y += h + BGY
    draw('v2-root-1-bands', '\n'.join(lines) + '\n')
    lines = []
    for title, mods, *_ in rows:
        bx, by = band_box[title]
        for m in mods:
            b = boxes[m]
            lines.append(f"subboard {q(m)} in {q(title)} {at(title, b.x - bx, b.y - by)} size: {SUB_W}x{SUB_H} public: true")
    obs = list(boxes.values())
    for m in PROD:
        for d in MODS[m]['deps']:
            bend = choose_bend(boxes[m], boxes[d], obs, frac=0.14, cap=240)
            lines.append(f"edge {q(m)} -> {q(d)}" + (f" bend: {bend}" if bend else ''))
    draw('v2-root-2-modules', '\n'.join(lines) + '\n')

def step_canvas():
    M = measured()
    A = about_title('Canvas')
    ring = ['Canvas/Editor', 'Canvas/Tools', 'Canvas/Rendering', 'Canvas/Shapes', 'Canvas/Plugins', 'Canvas/Schema',
            'Canvas/Persistence', 'Canvas/Model']
    R = 640
    cx, cy = ABOUT_W + BGX + R + SUB_W / 2, R + SUB_H / 2
    boxes = {}
    for i, t in enumerate(ring):
        a = -math.pi / 2 + i * 2 * math.pi / len(ring)
        boxes[t] = Box(cx + R * math.cos(a) - SUB_W / 2, cy + R * math.sin(a) - SUB_H / 2, SUB_W, SUB_H, t)
    style = ('Canvas', 'Style.swift')
    st = ftitle(style)
    lines = [f"sticky-note {q(A)} in \"Canvas\" size: {ABOUT_W}x{math.ceil(M[A])} text: {text_lit(about_text('Canvas'))}"]
    for t, b in boxes.items():
        lines.append(f"subboard {q(t)} in \"Canvas\" {at(A, b.x, b.y)} size: {SUB_W}x{SUB_H}")
    lines.append(f"sticky-note {q(st)} in \"Canvas\" {at(A, 0, math.ceil(M[A]) + BGY)} size: {note_w(st, True)}x{math.ceil(M[st])} public: true "
                 f"text: {text_lit(file_text(style))}")
    obs = list(boxes.values())
    agg = set()
    for e in model['edges']:
        if e['fromModule'] == 'Canvas' and e['toModule'] == 'Canvas':
            a, b = board_of(('Canvas', e['fromFile'])), board_of(('Canvas', e['toFile']))
            if a != b and a != 'Canvas' and b != 'Canvas':
                agg.add((a, b))
    done = set()
    for a, b in sorted(agg):
        if (a, b) in done: continue
        both = (b, a) in agg
        done |= {(a, b), (b, a)} if both else {(a, b)}
        bend = choose_bend(boxes[a], boxes[b], obs)
        lines.append(f"edge {q(a)} {'<->' if both else '->'} {q(b)}" + (f" bend: {bend}" if bend else ''))
    draw('v2-canvas-board', '\n'.join(lines) + '\n')

# ---- measuring ----------------------------------------------------------------------------------

def step_measure(mods):
    """Each note's height at its width: drawn on a scratch subboard at that width, then given its
    text (a note's size lasts until its text changes, and it then fits its text), then deleted."""
    notes = []
    if 'Canvas' in mods:
        notes.append((about_title('Canvas'), ABOUT_W, about_text('Canvas')))
        notes.append((ftitle(('Canvas', 'Style.swift')), note_w('Style.swift', True), file_text(('Canvas', 'Style.swift'))))
    for board in gen.boards_for(mods):
        notes.append((about_title(board), ABOUT_W, about_text(board)))
        _, other_all = gen.edges_between(set(PROD))
        notes += [(ftitle(k), note_w(ftitle(k), gen.is_public(k, other_all)), file_text(k)) for k in board_files(board)]
    if not notes:
        raise SystemExit('name the modules to measure')
    scratch = 'zz-measure'
    cli(f'delete {q(scratch)}\n', dry=False)
    draw('v2-measure-0', f'subboard {q(scratch)}\n')
    first = 'zz:' + notes[0][0]
    lines = [f"sticky-note {q(first)} in {q(scratch)} size: {notes[0][1]}x200 text: \"x\""]
    lines += [f"sticky-note {q('zz:' + t)} in {q(scratch)} below {q(first)} size: {w}x200 text: \"x\"" for t, w, _ in notes[1:]]
    draw('v2-measure-1', '\n'.join(lines) + '\n')
    rc, r = cli('\n'.join(f"sticky-note {q('zz:' + t)} text: {text_lit(tx)}" for t, w, tx in notes) + '\n', dry=False)   # overlaps don't matter here
    if 'error' in r:
        raise SystemExit(f"measuring refused: {r['error']}")
    M = measured()
    for c in r['changes']:
        if c.get('kind') == 'sticky-note' and c.get('title', '').startswith('zz:'):
            M[c['title'][3:]] = c['at'][1][1]
    json.dump(M, open(MEASURED, 'w'), indent=1)
    draw('v2-measure-3', f'delete {q(scratch)}\n')
    print(f"measured {len(notes)} notes; tallest {max(M[t] for t, _, _ in notes)}")

def about_height(board, M):
    """An About note's height: as measured, plus room for its mention pills' symbols, which a note's
    fit leaves out when its text comes from draw (dogfood/bugs.md, 3)."""
    text = about_text(board)
    n = text.count('@[')
    if not n:
        return math.ceil(M[about_title(board)])
    lines = math.ceil(n * 20 / (ABOUT_W - 32)) + 1
    return math.ceil(M[about_title(board)] + 19 * lines)

def step_about_pad(mods):
    M = measured()
    boards = gen.boards_for(mods) + (['Canvas'] if 'Canvas' in mods else [])
    for board in boards:
        draw(f'v2-about-{board.replace("/", "_")}', f"sticky-note {q(about_title(board))} size: {ABOUT_W}x{about_height(board, M)}\n")

if __name__ == '__main__':
    step, args = sys.argv[1], sys.argv[2:]
    dict(measure=step_measure, **{'about-pad': step_about_pad})[step](args)
