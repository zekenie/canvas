#!/usr/bin/env python3
"""The model every layout reads (model.json, its uses replaced by index_edges.json's), each note's text, and
the runner: every script is dry-run first, and a refusal, or a warning outside EXPECTED, stops it before the
real run."""
import json, math, os, re, subprocess, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from spec import BANDS, PURPOSES, CANVAS_FOLDERS, FOLDER_PURPOSES, GROUPS

CLI = '/Users/zekenie/code/native-canvas/build/canvas'
BOARD = os.environ.get('CANVAS_BOARD', '2')
RUNS = os.path.join(HERE, 'runs')
os.makedirs(RUNS, exist_ok=True)
MEASURED = os.path.join(HERE, 'measured.json')

model = json.load(open(os.path.join(HERE, 'model.json')))
# Which file uses which: the compiler's index (index_build.py, index_read.py), not the text.
model['edges'] = json.load(open(os.path.join(HERE, 'index_edges.json')))
MODS = {m['name']: m for m in model['modules']}
PROD = [m['name'] for m in model['modules'] if m['layer'] not in ('test', 'testsupport')]
FILES = {(f['module'], f['rel']): f for f in model['files'] if f['module'] in PROD}
LAYER_NAMES = {'foundation': 'foundation', 'wire': 'wire', 'ui': 'UI', 'surface': 'surface', 'concern': 'concern',
               'language': 'language', 'lexicon': 'lexicon', 'vertical': 'vertical', 'composition': 'composition',
               'app': 'app', 'appex': 'app extension', 'cli': 'command line'}

# ---- names --------------------------------------------------------------------------------------

_base_count = collections.Counter(os.path.basename(rel) for (m, rel) in FILES)

def ftitle(key):
    m, rel = key
    b = os.path.basename(rel)
    return f"{m}/{b}" if _base_count[b] > 1 else b

def board_of(key):
    m, rel = key
    if m == 'Canvas' and '/' in rel:
        return 'Canvas/' + rel.split('/')[0]
    return m

def board_files(board):
    if board.startswith('Canvas/'):
        folder = board.split('/', 1)[1]
        return sorted(k for k in FILES if k[0] == 'Canvas' and k[1].startswith(folder + '/'))
    return sorted(k for k in FILES if board_of(k) == board)

def key_in(board, name):
    """A file of a board by its name in the spec."""
    if board.startswith('Canvas/'):
        k = ('Canvas', board.split('/', 1)[1] + '/' + name)
    else:
        k = (board, name)
    if k not in FILES:
        raise SystemExit(f"spec names {name} on {board}, which has no such file")
    return k

def q(s):
    return '"' + s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n') + '"'

def plain(s):
    """Text with no mentions in it: an @[ is written as text."""
    return s.replace('@[', '\x00')

def text_lit(s):
    return q(s).replace('\x00', '\\\\@[')

# ---- what's drawn -------------------------------------------------------------------------------

def drawn_modules():
    return [m for m in PROD if os.path.exists(os.path.join(RUNS, f'drawn-{m}'))]

def edges_between(drawn):
    """File uses among drawn modules: same-board targets and other-board targets, per file."""
    same = collections.defaultdict(list)
    other = collections.defaultdict(list)
    for e in model['edges']:
        a, b = (e['fromModule'], e['fromFile']), (e['toModule'], e['toFile'])
        if a not in FILES or b not in FILES or a[0] not in drawn or b[0] not in drawn:
            continue
        if board_of(a) == board_of(b):
            same[a].append(b)
        else:
            other[a].append(b)
    for a in other:
        other[a].sort(key=lambda b: (board_of(b), ftitle(b)))
    return same, other

def is_public(key, other_all):
    f = FILES[key]
    if any(d['access'] in ('public', 'open') for d in f['decls']) or any(mb['access'] in ('public', 'open') for mb in f['members']):
        return True
    return any(key in targets for targets in other_all.values())

def file_text(key):
    f = FILES[key]
    parts = []
    if f['desc']:
        parts.append(f['desc'])
    decls = [d for d in f['decls'] if d['what'] in ('class', 'struct', 'enum', 'protocol', 'actor', 'typealias')]
    pub = [d['name'] for d in decls if d['access'] in ('public', 'open')]
    rest = [d['name'] for d in decls if d['access'] not in ('public', 'open', 'private', 'fileprivate')]
    priv = [d['name'] for d in decls if d['access'] in ('private', 'fileprivate')]
    exts = sorted(set(d['name'] for d in f['decls'] if d['what'] == 'extension') - set(d['name'] for d in decls))
    funcs = [d['name'] for d in f['decls'] if d['what'] == 'func' and d['access'] in ('public', 'open')]
    def names(xs, cap=10):
        return ', '.join(xs[:cap]) + (f' +{len(xs) - cap}' if len(xs) > cap else '')
    lines = []
    if pub: lines.append('public ' + names(pub))
    if rest: lines.append('internal ' + names(rest))
    if priv and not pub and not rest: lines.append('private ' + names(priv))
    if funcs: lines.append('public func ' + names(funcs, 6))
    if exts: lines.append('extends ' + names(exts, 6))
    lines.append(f"{f['lines']} lines")
    parts.append('\n'.join(lines))
    return plain('\n\n'.join(parts))

def about_title(board):
    return 'About ' + board

def about_text(board):
    if board.startswith('Canvas/'):
        folder = board.split('/', 1)[1]
        files = board_files(board)
        uses = collections.Counter()
        for e in model['edges']:
            if e['fromModule'] == 'Canvas' and e['toModule'] == 'Canvas':
                a, b = ('Canvas', e['fromFile']), ('Canvas', e['toFile'])
                if board_of(a) == board and board_of(b) != board:
                    uses[board_of(b)] += 1
        n = sum(FILES[k]['lines'] for k in files)
        t = f"{board}: a folder of @[Canvas]\n{FOLDER_PURPOSES[folder]}\n\nUses " + ' '.join(f'@[{u}]' for u in sorted(uses))
        return t + f"\n{len(files)} files, {n:,} lines"
    m = MODS[board]
    layer = LAYER_NAMES.get(m['layer'], m['layer'])
    users = [x for x in PROD if board in MODS[x]['deps']]
    t = f"{board}: {layer} layer\n{PURPOSES.get(board, '')}\n\n"
    t += ('Imports ' + ' '.join(f'@[{d}]' for d in m['deps'])) if m['deps'] else 'Imports no module of its own'
    if users:
        t += '\nImported by ' + (' '.join(f'@[{u}]' for u in users) if len(users) <= 12 else f'{len(users)} modules')
    files = [k for k in FILES if k[0] == board]
    t += f"\n{len(files)} files, {m['lines']:,} lines"
    if board == 'Canvas':
        t += '\nIts folders are subboards here.'
    return t

# ---- running scripts ----------------------------------------------------------------------------

EXPECTED = ('goes into a reference', 'comes from', 'write its title exactly', 'landed outside the view', 'held a board')

TIMEOUT = '240'     # canvas gives up after 10 s by default, while the app goes on drawing

def canvas(*args):
    """A canvas command's result (boards, query, show), or a SystemExit with what went wrong."""
    p = subprocess.run([CLI, '--timeout', TIMEOUT, *args], capture_output=True, text=True, timeout=600)
    if p.returncode:
        raise SystemExit(f"canvas {args[0]}: {(p.stderr.strip() or p.stdout.strip())[:400]}")
    return json.loads(p.stdout) if p.stdout.strip() else {}

def cli(script, dry):
    args = [CLI, '--timeout', TIMEOUT, 'draw', '--board', BOARD] + (['--dry-run'] if dry else []) + ['-']
    p = subprocess.run(args, input=script, capture_output=True, text=True, timeout=600)
    out = p.stdout.strip() or p.stderr.strip()
    try:
        return p.returncode, json.loads(out)
    except json.JSONDecodeError:
        return p.returncode, {'error': {'message': out}}

def draw(label, script, real=True):
    open(os.path.join(RUNS, label + '.draw'), 'w').write(script)
    rc, r = cli(script, dry=True)
    json.dump(r, open(os.path.join(RUNS, label + '.dry.json'), 'w'), indent=1)
    if 'error' in r:
        print(f"[{label}] refused: {json.dumps(r['error'])[:1500]}")
        sys.exit(1)
    odd = [w for w in r.get('warnings', []) if not any(x in w['message'] for x in EXPECTED)]
    if odd:
        print(f"[{label}] dry run warns:")
        for w in odd[:30]:
            print('   ', w.get('line'), w['message'][:300])
        sys.exit(1)
    if not real:
        return r
    rc, r = cli(script, dry=False)
    json.dump(r, open(os.path.join(RUNS, label + '.json'), 'w'), indent=1)
    if 'error' in r:
        print(f"[{label}] refused on the real run: {json.dumps(r['error'])[:1500]}")
        sys.exit(1)
    kinds = collections.Counter((c.get('kind'), c['did']) for c in r['changes'])
    print(f"[{label}] on {r.get('on', {}).get('title') or r.get('on', {}).get('board')}: " +
          ', '.join(f'{n} {k} {d}' for (k, d), n in sorted(kinds.items(), key=lambda x: str(x))))
    return r

# ---- layout -------------------------------------------------------------------------------------

GX, GY = 80, 80          # between notes in a grid
PAD = 40                 # what `in` leaves inside a frame
BGX, BGY = 120, 160      # between blocks on a board
SUB = 80                 # between subframes, and between a frame's notes and its subframes

def pill_w(title):
    return min(280, 70 + 7.6 * len(title))

def cols_for(n):
    return n if n <= 3 else 2 if n == 4 else 3 if n <= 9 else 4

class Unit:
    def __init__(self, key, title, text, nat_h, pills, public):
        self.key, self.title, self.text, self.public = key, title, text, public
        self.k = len(pills)
        self.pw = max((pill_w(p) for p in pills), default=0)
        self.w = 200 + (GX + self.pw if self.k else 0)
        self.list_h = 96 * self.k - 64 if self.k else 0
        self.h = max(nat_h, self.list_h)
        self.sized = self.list_h > nat_h

class Grid:
    def __init__(self, units, cols=None):
        self.units = units
        n = len(units)
        self.C = cols or cols_for(n)
        self.R = math.ceil(n / self.C) if n else 0
        self.cw = [max(u.w for i, u in enumerate(units) if i % self.C == c) for c in range(min(self.C, n))]
        self.rh = [max(u.h for i, u in enumerate(units) if i // self.C == r) for r in range(self.R)]
        self.w = sum(self.cw) + GX * (len(self.cw) - 1) if n else 0
        self.h = sum(self.rh) + GY * (self.R - 1) if n else 0

    def placements(self):
        """Each unit's placement against the others: the first has none."""
        out = []
        for i, u in enumerate(self.units):
            r, c = divmod(i, self.C)
            if i == 0:
                out.append('')
            elif c > 0:
                left = self.units[i - 1]
                out.append(f"right of {q(left.title)} (gap: {int(self.cw[c - 1] - 200 + GX)}) top level with {q(left.title)}")
            else:
                above = [x.title for x in self.units[(r - 1) * self.C:r * self.C]]
                out.append(f"below {targets(above)} (gap: {GY}) left level with {q(self.units[(r - 1) * self.C].title)}")
        return out

def targets(titles):
    qs = [q(t) for t in titles]
    return qs[0] if len(qs) == 1 else ', '.join(qs[:-1]) + ' and ' + qs[-1]

class Frame:
    def __init__(self, title, units, subs):
        self.title, self.grid, self.subs = title, Grid(units), subs
        rw = sum(s.w for s in subs) + SUB * (len(subs) - 1) if subs else 0
        rh = max((s.h for s in subs), default=0)
        inner_w = max(self.grid.w, rw)
        inner_h = self.grid.h + (SUB if units and subs else 0) + rh
        self.w, self.h = int(math.ceil(inner_w + 2 * PAD)), int(math.ceil(inner_h + 2 * PAD))

    def walk(self, depth=1):
        yield self, depth
        for s in self.subs:
            yield from s.walk(depth + 1)

def shelf(blocks):
    """Rows of (title, w, h) blocks, wrapped near a 16:10 width."""
    area = sum(w * h for _, w, h in blocks)
    target = max(max(w for _, w, _ in blocks), math.sqrt(area * 1.6))
    rows, cur, x = [], [], 0
    for b in blocks:
        if cur and x + BGX + b[1] > target:
            rows.append(cur); cur, x = [], 0
        x += (BGX if cur else 0) + b[1]
        cur.append(b)
    if cur: rows.append(cur)
    return rows

def shelf_placements(rows):
    out = {}
    for ri, row in enumerate(rows):
        for ci, (t, w, h) in enumerate(row):
            if ri == 0 and ci == 0:
                out[t] = ''
            elif ci > 0:
                out[t] = f"right of {q(row[ci - 1][0])} (gap: {BGX}) top level with {q(row[ci - 1][0])}"
            else:
                prev = rows[ri - 1]
                out[t] = f"below {targets([b[0] for b in prev])} (gap: {BGY}) left level with {q(prev[0][0])}"
    return out

# ---- steps --------------------------------------------------------------------------------------

LEGEND = "How to read this board"
LEGEND_TEXT = ("This board is Infinite Canvas, drawn from its own code by canvas draw.\n\n"
               "• A subboard is a module, a target in Package.swift, in its layer's frame. Open it to see its files.\n"
               "• An arrow between modules: the first imports the second.\n"
               "• On a module's board, a note is a source file: what its main doc comment says first, what it declares, how long it is. "
               "A frame groups files. Canvas's folders are subboards of their own.\n"
               "• An arrow between notes: the first file uses something the second declares.\n"
               "• A pill beside a note is a file on another board whose declarations that file uses. Its symbol goes there.\n"
               "• Public: the file declares public API, or a file on another board uses it.")

def step_root():
    band_rows = []
    for title, mods in BANDS:
        C = min(len(mods), 7)
        R = math.ceil(len(mods) / C)
        band_rows.append((title, mods, C, R))
    W = max(2 * PAD + C * 240 + (C - 1) * BGX for _, _, C, _ in band_rows)
    lines = [f"sticky-note {q(LEGEND)} text: {text_lit(LEGEND_TEXT)}"]
    prev = LEGEND
    for title, mods, C, R in band_rows:
        H = 2 * PAD + R * 160 + (R - 1) * BGX
        lines.append(f"frame {q(title)} size: {W}x{H} below {q(prev)} (gap: {BGY}) left level with {q(prev)}")
        prev = title
    draw('root-1-bands', '\n'.join(lines) + '\n')
    lines = []
    for title, mods, C, R in band_rows:
        for i, m in enumerate(mods):
            r, c = divmod(i, C)
            if i == 0:
                place = ''
            elif c > 0:
                place = f" right of {q(mods[i - 1])} (gap: {BGX}) top level with {q(mods[i - 1])}"
            else:
                place = f" below {targets(mods[(r - 1) * C:r * C])} (gap: {BGX}) left level with {q(mods[(r - 1) * C])}"
            lines.append(f"subboard {q(m)} in {q(title)}{place} public: true")
    for m in PROD:
        for d in MODS[m]['deps']:
            lines.append(f"edge {q(m)} -> {q(d)}")
    draw('root-2-modules', '\n'.join(lines) + '\n')

def step_canvas():
    folders = ['Canvas/' + f for f in CANVAS_FOLDERS]
    grid = [['Canvas/Editor', 'Canvas/Tools', 'Canvas/Rendering', 'Canvas/Plugins'],
            ['Canvas/Model', 'Canvas/Shapes', 'Canvas/Schema', 'Canvas/Persistence']]
    assert sorted(sum(grid, [])) == sorted(folders)
    style = ('Canvas', 'Style.swift')
    lines = [f"sticky-note {q(about_title('Canvas'))} in \"Canvas\" text: {text_lit(about_text('Canvas'))}"]
    for r, row in enumerate(grid):
        for c, t in enumerate(row):
            if c > 0:
                place = f"right of {q(row[c - 1])} (gap: 200) top level with {q(row[c - 1])}"
            elif r == 0:
                place = f"right of {q(about_title('Canvas'))} (gap: 200) top level with {q(about_title('Canvas'))}"
            else:
                place = f"below {targets(grid[0])} (gap: 200) left level with {q(grid[0][0])}"
            lines.append(f"subboard {q(t)} in \"Canvas\" {place} public: true")
    lines.append(f"sticky-note {q(ftitle(style))} in \"Canvas\" below {targets([about_title('Canvas')] + grid[1])} (gap: {BGY}) "
                 f"left level with {q(about_title('Canvas'))} public: true text: {text_lit(file_text(style))}")
    agg = set()
    for e in model['edges']:
        if e['fromModule'] == 'Canvas' and e['toModule'] == 'Canvas':
            a, b = board_of(('Canvas', e['fromFile'])), board_of(('Canvas', e['toFile']))
            if a != b and a != 'Canvas' and b != 'Canvas':
                agg.add((a, b))
    done = set()
    for a, b in sorted(agg):
        if (a, b) in done: continue
        if (b, a) in agg:
            lines.append(f"edge {q(a)} <-> {q(b)}"); done |= {(a, b), (b, a)}
        else:
            lines.append(f"edge {q(a)} -> {q(b)}"); done.add((a, b))
    draw('canvas-board', '\n'.join(lines) + '\n')

def boards_for(mods):
    out = []
    for m in mods:
        if m == 'Canvas':
            out += ['Canvas/' + f for f in CANVAS_FOLDERS]
        else:
            out.append(m)
    return out

def step_measure(mods):
    measured = json.load(open(MEASURED)) if os.path.exists(MEASURED) else {}
    for board in boards_for(mods):
        keys = board_files(board)
        notes = [(about_title(board), text_lit(about_text(board)))] + [(ftitle(k), text_lit(file_text(k))) for k in keys]
        lines = [f"sticky-note {q(notes[0][0])} in {q(board)} text: {notes[0][1]}"]
        lines += [f"sticky-note {q(t)} in {q(board)} below {q(notes[0][0])} text: {tx}" for t, tx in notes[1:]]
        r = draw(f'measure-{board.replace("/", "_")}', '\n'.join(lines) + '\n', real=False)
        for c in r['changes']:
            if c.get('kind') == 'sticky-note':
                measured[c['title']] = c['at'][1][1]
        print(f"[measure {board}] {len(notes)} notes, tallest {max(measured[t] for t, _ in notes)}")
    json.dump(measured, open(MEASURED, 'w'), indent=1)

def board_layout(board, drawn):
    measured = json.load(open(MEASURED))
    same, other = edges_between(drawn)
    _, other_all = edges_between(set(PROD))
    def unit(k):
        return Unit(k, ftitle(k), file_text(k), measured[ftitle(k)], [ftitle(t) for t in other.get(k, [])], is_public(k, other_all))
    about = Unit(None, about_title(board), about_text(board), measured[about_title(board)], [], False)
    spec = GROUPS.get(board)
    if not spec:
        return about, None, [unit(k) for k in board_files(board)]
    def build(g):
        title, names, subs = g
        return Frame(title, [unit(key_in(board, n)) for n in names], [build(s) for s in subs])
    frames = [build(g) for g in spec]
    listed = [u.key for f in frames for fr, _ in f.walk() for u in fr.grid.units]
    missing = set(board_files(board)) - set(listed)
    if missing:
        raise SystemExit(f"{board}: the spec leaves out {sorted(ftitle(k) for k in missing)}")
    return about, frames, None

def note_line(u, holder, place):
    attrs = []
    if u.sized: attrs.append(f"size: 200x{int(math.ceil(u.h))}")
    if u.public: attrs.append("public: true")
    parts = [f"sticky-note {q(u.title)} in {q(holder)}"] + ([place] if place else []) + attrs + [f"text: {text_lit(u.text)}"]
    return ' '.join(parts)

def step_boards(mods):
    drawn = set(drawn_modules()) | set(mods)
    for board in boards_for(mods):
        about, frames, flat = board_layout(board, drawn)
        label = board.replace('/', '_')
        if frames is None:
            grid = Grid([about] + flat)
            lines = []
            for u, place in zip(grid.units, grid.placements()):
                if u is about:
                    lines.append(f"sticky-note {q(u.title)} in {q(board)} text: {text_lit(u.text)}")
                else:
                    lines.append(note_line(u, board, place))
            draw(f'board-{label}-notes', '\n'.join(lines) + '\n')
            continue
        rows = shelf([(about.title, about.w, about.h)] + [(f.title, f.w, f.h) for f in frames])
        places = shelf_placements(rows)
        lines = [f"sticky-note {q(about.title)} in {q(board)} text: {text_lit(about.text)}"]
        for f in frames:
            lines.append(f"frame {q(f.title)} in {q(board)} size: {f.w}x{f.h} {places[f.title]}")
        draw(f'board-{label}-frames', '\n'.join(lines) + '\n')
        depth = 2
        while True:
            lines = []
            for top in frames:
                for fr, d in top.walk():
                    if d != depth - 1 or not fr.subs:
                        continue
                    for i, s in enumerate(fr.subs):
                        if i == 0:
                            place = 'inside ' + q(fr.title) + ' bottom-left' if fr.grid.units else ''
                        else:
                            side = 'bottom' if fr.grid.units else 'top'
                            place = f"right of {q(fr.subs[i - 1].title)} (gap: {SUB}) {side} level with {q(fr.subs[i - 1].title)}"
                        lines.append(f"frame {q(s.title)} in {q(fr.title)} size: {s.w}x{s.h} {place}".rstrip())
            if not lines:
                break
            draw(f'board-{label}-frames-{depth}', '\n'.join(lines) + '\n')
            depth += 1
        lines = []
        for top in frames:
            for fr, _ in top.walk():
                for u, place in zip(fr.grid.units, fr.grid.placements()):
                    lines.append(note_line(u, fr.title, place))
        draw(f'board-{label}-notes', '\n'.join(lines) + '\n')
    for m in mods:
        open(os.path.join(RUNS, f'drawn-{m}'), 'w').write('')

def step_edges(mods):
    drawn = set(drawn_modules())
    same, other = edges_between(drawn)
    for board in boards_for(mods) + (['Canvas'] if 'Canvas' in mods else []):
        keys = board_files(board)
        lines = []
        for k in keys:
            for t in other.get(k, []):
                lines.append(f"edge {q(ftitle(k))} -> {q(ftitle(t))}")
        done = set()
        for k in keys:
            for t in sorted(set(same.get(k, [])), key=ftitle):
                if (k, t) in done: continue
                if k in same.get(t, []):
                    lines.append(f"edge {q(ftitle(k))} <-> {q(ftitle(t))}"); done |= {(k, t), (t, k)}
                else:
                    lines.append(f"edge {q(ftitle(k))} -> {q(ftitle(t))}"); done.add((k, t))
        if lines:
            draw(f'edges-{board.replace("/", "_")}', '\n'.join(lines) + '\n')
