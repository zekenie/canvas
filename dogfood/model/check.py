#!/usr/bin/env python3
"""Checks what's drawn against a generator's plan: every titled shape where the plan puts it and as big,
every group frame holding the pills planned for it, each where planned, no pill outside a group frame,
and as many arrows as planned. Reads the board file through the gallery test's dump.
    GALLERY_CLONE=<clone> check.py gen5 [board...]   the root, Canvas's board and every module's (or the ones named)
GALLERY_CLONE is a scratch clone whose CompositionTests run GalleryCapture.swift.txt (README.md)."""
import collections, importlib, json, os, statistics, subprocess, sys, time
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from gen2 import Box, ABOUT_W

GALLERY = os.path.abspath(os.path.expanduser(os.environ['GALLERY_CLONE'])) if os.environ.get('GALLERY_CLONE') else ''
DUMP = os.path.join(HERE, 'runs', 'dump.jsonl')
TOL = 2

def board_file(G):
    """The file of the board the generator draws on (gen.BOARD), once the app has saved what was drawn."""
    for _ in range(90):
        board = next((b for b in G.gen.canvas('boards') if str(G.gen.BOARD) in (str(b['id']), b['name'], b.get('path'))), None)
        if board is None or not board.get('path'):
            raise SystemExit(f"board {G.gen.BOARD} isn't open in the app, or has no file")
        if not board['edited']:
            return board['path']
        time.sleep(1)
    raise SystemExit(f"board {G.gen.BOARD} still has unsaved changes after 90 s")

def dump(G):
    """Every board's shapes, as the board file has them: {board: [row]}, a board by its owner's title."""
    if not GALLERY:
        raise SystemExit("set GALLERY_CLONE to the clone that runs the gallery capture (README.md)")
    path = board_file(G)
    os.makedirs(os.path.dirname(DUMP), exist_ok=True)
    if os.path.exists(DUMP):
        os.remove(DUMP)     # a capture that runs no test exits 0 and writes nothing
    env = dict(os.environ, GALLERY_FILE=path, GALLERY_OUT=os.path.dirname(DUMP), GALLERY_BOARDS='none',
               GALLERY_DUMP=DUMP, TEST_FILTER='Gallery')
    p = subprocess.run([os.path.join(GALLERY, 'build/debug/CompositionTests/CompositionTests')], cwd=GALLERY, env=env,
                       capture_output=True, text=True)
    if p.returncode or not os.path.exists(DUMP):
        raise SystemExit(f"dump failed: {p.stdout[-400:]}{p.stderr[-400:]}")
    by = collections.defaultdict(list)
    for line in open(DUMP):
        r = json.loads(line)
        by[r['board']].append(r)
    return by

def groups_of(col, s):
    """A column's group frames beside a start whose box is s, each with its pills."""
    pills, frames = col.place(s)
    out, i = [], 0
    for fr, (_, ps) in zip(frames, col.groups):
        out.append((fr, pills[i:i + len(ps)]))
        i += len(ps)
    return out

class Checker:
    """One board's rows against its plan. `anchors` are (title, x, y), shapes and where the plan puts them: the
    plan's origin on the board is the median of their offsets, so a displaced anchor is reported, not the rest."""
    def __init__(self, rows, anchors):
        self.rows, self.off, self.seen = rows, [], set()
        self.titled = {r['title']: r for r in rows if r['title'] and r['kind'] not in ('reference', 'arrow')}
        offs = [(self.titled[t]['x'] - x, self.titled[t]['y'] - y) for t, x, y in anchors if t in self.titled]
        self.ox, self.oy = (statistics.median([o[0] for o in offs]), statistics.median([o[1] for o in offs])) if offs else (None, None)
        if not offs:
            self.off.append(f"{anchors[0][0]} isn't there")

    def box(self, b, size=True):
        if self.ox is None: return
        r = self.titled.get(b.name)
        if not r:
            self.off.append(f"{b.name}: missing"); return
        self.seen.add(b.name)
        dx, dy = r['x'] - self.ox - b.x, r['y'] - self.oy - b.y
        if abs(dx) > TOL or abs(dy) > TOL:
            self.off.append(f"{b.name}: off by ({dx:+.0f}, {dy:+.0f})")
        if size and (abs(r['w'] - b.w) > TOL or abs(r['h'] - b.h) > TOL):
            self.off.append(f"{b.name}: {r['w']:.0f}x{r['h']:.0f}, not {b.w:.0f}x{b.h:.0f}")

    def group(self, frame, pills, side):
        """A group frame, the pills in it standing for what the plan says, each where planned: its left
        edge, right of its note; its right edge, left of it (a pill's width is the app's)."""
        self.box(frame)
        r = self.titled.get(frame.name)
        if not r or self.ox is None: return
        inside = [p for p in self.rows if p['kind'] == 'reference'
                  and r['x'] <= p['x'] + p['w'] / 2 <= r['x'] + r['w'] and r['y'] <= p['y'] + p['h'] / 2 <= r['y'] + r['h']]
        self.seen |= {p['id'] for p in inside}
        got, want = sorted(p['for'] for p in inside), sorted(b.name for b in pills)
        if got != want:
            self.off.append(f"{frame.name}: holds {got}, not {want}"); return
        for b, p in zip(sorted(pills, key=lambda b: b.y), sorted(inside, key=lambda p: p['y'])):
            dx = (p['x'] - self.ox - b.x) if side == 'r' else (p['x'] + p['w'] - self.ox - (b.x + b.w))
            dy = p['y'] - self.oy - b.y
            if abs(dx) > TOL or abs(dy) > TOL:
                self.off.append(f"pill {b.name} in {frame.name}: off by ({dx:+.0f}, {dy:+.0f})")

    def rest(self, arrows):
        stray = [p for p in self.rows if p['kind'] == 'reference' and p['id'] not in self.seen]
        if stray:
            self.off.append(f"{len(stray)} pills in no group frame: {sorted(set(p['for'] for p in stray))[:6]}")
        extra = [r['title'] or r['kind'] for r in self.rows if r['kind'] not in ('reference', 'arrow') and r['title'] not in self.seen]
        if extra:
            self.off.append(f"not in the plan: {extra[:6]}")
        n = sum(1 for r in self.rows if r['kind'] == 'arrow')
        if n != arrows:
            self.off.append(f"{n} arrows, not {arrows}")

def check_board(G, board, rows):
    about, frames, notes, _, _ = G.plan_for(board)
    c = Checker(rows, [(about.title, 0, 0)])
    c.box(Box(0, 0, ABOUT_W, about.nh, about.title))
    for f in frames:
        c.box(Box(f['bx'], f['by'], f['w'], f['h'], f['title']))
    for n in notes:
        c.box(n['box'])
        u = n['unit']
        for col in (u.right, u.left):
            for fr, ps in groups_of(col, n['box']):
                c.group(fr, ps, col.side)
    pilled = G.decide_board(board)
    kept = sum(1 for k, t, _ in G.board_pairs(board) if (k, t) not in pilled)
    c.rest(kept + sum(len(n['unit'].right.pills) + len(n['unit'].left.pills) for n in notes))
    return c.off

def check_root(G, rows):
    pilled, lay = G.root_decide()
    c = Checker(rows, [(b['title'], b['x'], b['y']) for b in lay.bands])     # the note the root hangs from is gone
    for b in lay.bands:
        c.box(Box(b['x'], b['y'], b['w'], b['h'], b['title']))
    for m in G.PROD:
        c.box(lay.card[m])
        for col in lay.cols[m]:
            for fr, ps in groups_of(col, lay.card[m]):
                c.group(fr, ps, col.side)
    c.rest(len([e for e in G.EDGES if e not in pilled]) + len(pilled))
    return c.off

def main(G, only):
    by = dump(G)
    reports = []
    if not only or 'root' in only:
        reports.append(('root', check_root(G, by['root'])))
    for board in G.drawn_boards():
        if not only or board in only:
            reports.append((board, check_board(G, board, by[board])))
    for board, off in reports:
        if off:
            print(f"{board}: {len(off)} off")
            for o in off[:10]:
                print(f"    {o}")
    good = sum(1 for _, off in reports if not off)
    print(f"{sum(len(by[b]) for b in by)} shapes read; {len(reports)} boards checked, {good} as planned, "
          f"{sum(len(off) for _, off in reports)} problems")

if __name__ == '__main__':
    main(importlib.import_module(sys.argv[1]), sys.argv[2:])
