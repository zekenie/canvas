#!/usr/bin/env python3
"""Layout v5. Which uses between a board's files are arrows comes from heuristic.py: a board's hubs, and
the arrows two stronger ones already relay, are pills; so is an arrow that would cross more than ALLOW
lets it. A frame whose files have arrows between them is a ladder: two columns, pills on the outer sides,
the arrows between them. A module with folder boards (Canvas) is drawn the same way, its folders' cards in place of notes.
Pills are grouped by where they come from, each group in a frame titled "<where> (<note>)". Draw stacks a
start's pills as a group packs them, but with no gaps between groups for their frames' titles, so notes go
first in a staging area, the groups move into place in temporary frames, and the notes go home. On the root, an import is an arrow only when it clears every shape but its
ends after a small bend and its end takes no more than CAP arrows. The root hangs from a temporary note,
deleted once its pills are home.
    gen5.py plan                  checks every board's plan, draws nothing
    gen5.py reset                 deletes what's drawn, and the marks of what was
    gen5.py all                   draws what isn't drawn yet (resumable: runs/v9-done-*)
    check.py gen5                 the board against the plan"""
import hashlib, json, math, os, sys, collections
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen, gen2
from gen import (q, text_lit, ftitle, bare, board_of, board_files, folder_boards, key_in, file_text, about_text, about_title,
                 PROD, MODS, FILES, USES, BOARDS, BANDS, GROUPS, BY_MODULE, FOLDER_BOARDS, draw, cli, RUNS)
from gen2 import Box, arc_points, at, note_w, list_h, pill_w, measured, ABOUT_W, SUB_W, SUB_H, PILL_GAP, PILL_PITCH, PILL_H, FRAME_MIN_H

P = 64                  # inside a frame, from each edge: `in` needs 40, a group frame reaches 16 past its pills
GX, GY = 80, 96         # between units
BGX, BGY = 160, 200     # between blocks
SUB = 112               # above a frame's subframes
PADF, SLACK, TITLE = 12, 24, 40   # a group frame past its pills (a lone pill's, centered in the smallest frame); more on the ragged side; its title, above it
TPITCH = PILL_PITCH     # a pill and the gap under it, packed: as draw stacks them, so a group moves whole
FRAME_GAP = 64          # between two group frames: the lower one's title, clear to about 42% (draw's list step)
PGAP, PGAP_MAX = 100, 260   # from a note to its pills, packed: farther for a tall column, so its fan isn't steep
TALL = 640              # a file's column taller than this splits, its later groups going left
DRAW_GAP = PILL_GAP     # where draw puts them first
STAGE_GAP, STAGE_W = 200, 12000
LAYER_OF = {m: t for t, ms in BANDS for m in ms}
LAYER_RANK = {t: i for i, (t, _) in enumerate(BANDS)}
CAP = 6                 # arrows into one module on the root
ROOT_SPLIT = 4          # a root card with more slots than this puts groups on both sides
UGX, RGY, BANDGAP, HEADER = 200, 160, 200, 30
ANCHOR, ANCHOR_W = 'zz-root', 200    # a note the root's shapes hang from while they're drawn
LEGEND = 'How to read this board'     # the root's legend, on a board drawn before it was dropped: reset deletes it

# ---- a column of grouped pills -------------------------------------------------------------------

class Column:
    """One side's pills, in groups, each group in a frame: packed TPITCH apart where they end up, and,
    where draw first puts them, a list PILL_PITCH apart, DRAW_GAP out."""
    def __init__(self, owner, groups, side, via=()):
        self.owner, self.groups, self.side, self.via = owner, [(g, ps) for g, ps in groups if ps], side, set(via)
        self.pills = [p for _, ps in self.groups for p in ps]
        self.fh = [max(FRAME_MIN_H, 2 * PADF + list_h(len(ps))) for _, ps in self.groups]
        self.H = (sum(self.fh) + FRAME_GAP * (len(self.groups) - 1)) if self.groups else 0
        self.fw = [math.ceil(max(max(pill_w(p) for p in ps) + 2 * PADF + SLACK, min(300, 6 * len(self.frame_title(g)) + 24))) for g, ps in self.groups]
        self.gap = min(PGAP_MAX, max(PGAP, round(0.25 * self.H)))
        self.reach = (self.gap - PADF + max(self.fw)) if self.groups else 0
        self.ext = (self.H + 2 * TITLE) if self.groups else 0
        self.L0 = list_h(len(self.pills))
        self.reach0 = (DRAW_GAP + max(pill_w(p) for p in self.pills) + 40) if self.pills else 0

    def frame_title(self, g):
        return f"{g} ({bare(self.owner)})"

    def place(self, s):
        """The pills' boxes and the group frames' boxes, packed beside a start whose box is s."""
        y = s.y + s.h / 2 - self.H / 2
        pills, frames = [], []
        for gi, (g, ps) in enumerate(self.groups):
            w = self.fw[gi]
            fx = s.x + s.w + self.gap - PADF if self.side == 'r' else s.x - self.gap + PADF - w
            frames.append(Box(fx, y, w, self.fh[gi], self.frame_title(g)))
            top = y + (self.fh[gi] - list_h(len(ps))) / 2
            for j, p in enumerate(ps):
                pw = pill_w(p)
                px = s.x + s.w + self.gap if self.side == 'r' else s.x - self.gap - pw
                pills.append(Box(px, top + j * TPITCH, pw, PILL_H, p))
            y += self.fh[gi] + FRAME_GAP
        return pills, frames

    def drawn(self, s):
        """Where draw puts the pills beside a start whose box is s: a list, centered on it."""
        top = s.y + s.h / 2 - self.L0 / 2
        out = []
        for j, p in enumerate(self.pills):
            pw = pill_w(p)
            px = s.x + s.w + DRAW_GAP if self.side == 'r' else s.x - DRAW_GAP - pw
            out.append(Box(px, top + j * PILL_PITCH, pw, PILL_H, p))
        return out

    def by_group(self, pills):
        """A column's pills (as place or drawn gives them), group by group."""
        out, i = [], 0
        for _, ps in self.groups:
            out.append(pills[i:i + len(ps)])
            i += len(ps)
        return out

    def carrier(self, pills):
        """A temporary frame round these pills, with room for their widths to be off my estimate on their
        ragged side: from 4 above the first, down to 4 below the last, or further, to the smallest frame."""
        w = max(p.w for p in pills)
        x = pills[0].x - 8 if self.side == 'r' else pills[0].x + pills[0].w + 8 - (w + 40)
        top = pills[0].y - 4
        return Box(x, top, w + 40, max(FRAME_MIN_H, pills[-1].y + PILL_H + 4 - top))

    def moves(self, s0, s1):
        """How the pills get from where draw puts them beside a start whose box is s0 to their groups beside it
        at s1: two rounds of temporary frames, each a list of (where a frame is drawn, where it goes). Draw
        stacks them as a group packs them, so a group moves whole; but a frame is at least FRAME_MIN_H tall,
        and in draw's list a group of one pill has only 16 above and below it, so the groups go home in pairs
        first, each pair's frame moved so its first group lands home (the last group, alone, at the list's
        end, with room below it), then each pair's second group on its own, from just below the first,
        its frame reaching down into the gap it's headed for."""
        drawn, home = self.by_group(self.drawn(s0)), self.by_group(self.place(s1)[0])
        def shifted(b, d):
            return Box(b.x + d[0], b.y + d[1], b.w, b.h, b.name)
        def delta(a, b):
            return (b[0].x - a[0].x, b[0].y - a[0].y)
        first, second = [], []
        for i in range(0, len(drawn), 2):
            d = delta(drawn[i], home[i])
            frame = self.carrier(drawn[i] + (drawn[i + 1] if i + 1 < len(drawn) else []))
            first.append((frame, shifted(frame, d)))
            if i + 1 < len(drawn):
                after = [shifted(p, d) for p in drawn[i + 1]]
                frame = self.carrier(after)
                second.append((frame, shifted(frame, delta(after, home[i + 1]))))
        return first, second

    def edges(self, start, via=False):
        side = ' from: left' if self.side == 'l' else ''
        return [f"edge {q(start)} -> {q(p)}{' via: reference' if via or p in self.via else ''}{side}" for p in self.pills]

def split(owner, groups, limit, via=(), tall=None):
    """Groups on the right, or, past `limit` pills (or a column `tall`), the first ones right and the
    rest left, the two columns as near the same height as whole groups allow."""
    over = Column(owner, groups, 'r').H > tall if tall else sum(len(ps) for _, ps in groups) > limit
    if not over or len(groups) < 2:
        return Column(owner, groups, 'r', via), Column(owner, [], 'l')
    i = min(range(1, len(groups)), key=lambda i: max(Column(owner, groups[:i], 'r').H, Column(owner, groups[i:], 'l').H))
    return Column(owner, groups[:i], 'r', via), Column(owner, groups[i:], 'l', via)

# ---- what a file's pills are --------------------------------------------------------------------

def where_from(src, t):
    """A file's pill is grouped by the module of the file it stands for; within a module with folder boards,
    by the board."""
    return board_of(t) if src[0] == t[0] and src[0] in FOLDER_BOARDS else t[0]

def rank(where):
    m = BOARDS[where][0]
    return (LAYER_RANK[LAYER_OF[m]], where)

def file_columns(k, other, mine=()):
    """A file's columns: the files it uses on other boards, and the ones on its own board in `mine`,
    grouped by where they come from (its own module first); for a file in BY_MODULE, the modules it
    uses, grouped by layer, on both sides."""
    t = ftitle(k)
    if k in BY_MODULE:
        mods = sorted(set(x[0] for x in other.get(k, []) if x[0] != k[0]), key=lambda m: (LAYER_RANK[LAYER_OF[m]], m))
        groups = [(short(layer), [m for m in mods if LAYER_OF[m] == layer]) for layer, _ in BANDS]
        groups = [(g, ps) for g, ps in groups if ps]
        if mine:
            groups.insert(0, (where_from(k, k), sorted(ftitle(x) for x in mine)))
        return split(t, groups, 0, via=[ftitle(x) for x in mine])
    by = collections.defaultdict(list)
    for x in list(other.get(k, [])) + list(mine):
        by[where_from(k, x)].append(ftitle(x))
    own = where_from(k, k)
    groups = [(g, sorted(by[g])) for g in sorted(by, key=lambda g: (g != own, rank(g)))]
    return split(t, groups, None, via=[ftitle(x) for x in mine], tall=TALL)

def short(layer):
    return layer.replace(' layer', '')

def title_of(k):
    """A file's title, or a folder's (a module with folder boards has a card for each, called by the folder's board)."""
    return k if isinstance(k, str) else ftitle(k)

# ---- a module with folder boards: its folders' cards, the uses between them, and its other files -------

def folder_uses(m):
    """(a, b): how many of a's files use something one of b's files declares, a and b folder boards of m."""
    folders = set(folder_boards(m))
    pairs = set()
    for x, y, _ in USES:
        if x[0] == m and y[0] == m:
            a, b = board_of(x), board_of(y)
            if a != b and a in folders and b in folders:
                pairs.add((a, b, x[1], y[1]))
    return collections.Counter((a, b) for a, b, _, _ in pairs)

def card_unit(f, pilled):
    """A folder's card and its pills, for the folders it uses through them, in one group: its module's."""
    m, folder = BOARDS[f]
    ts = sorted(t for a, t in pilled if a == f)
    right, left = split(folder, [(m, ts)] if ts else [], ROOT_SPLIT, via=ts)
    return Unit(f, None, SUB_W, SUB_H, True, right, left, key=f, kind='subboard')

# ---- a board's plan -------------------------------------------------------------------------------

class Unit:
    """A note (or, on the board of a module with folder boards, a folder's card) and its columns."""
    def __init__(self, title, text, w, h, public, right, left, key=None, kind='sticky-note'):
        self.title, self.text, self.w, self.nh, self.public, self.key, self.kind = title, text, w, h, public, key, kind
        self.right, self.left = right, left
        self.lx = left.reach
        self.uw = self.lx + w + right.reach
        self.uh = max(h, right.ext, left.ext)
        # in the staging area, where draw's lists need room
        self.lx0 = left.reach0
        self.uw0 = self.lx0 + w + right.reach0
        self.uh0 = max(h, right.L0, left.L0) + 2 * TITLE

def cols_for(n):
    return n if n <= 3 else 2 if n == 4 else 3 if n <= 9 else 4

def chain_order(units, arrows):
    """Walks along the arrows between these units' files, each step to the neighbor with the fewest
    links left, each walk from the file with the fewest; then the files with no arrow, in the spec's
    order. Returns the walks and the rest."""
    keys = [u.key for u in units]
    pos = {k: i for i, k in enumerate(keys)}
    adj = {k: set() for k in keys}
    for a, b in arrows:
        if a in adj and b in adj and a != b:
            adj[a].add(b); adj[b].add(a)
    seen, walks = set(), []
    while True:
        todo = [k for k in keys if adj[k] and k not in seen]
        if not todo: break
        walk = [min(todo, key=lambda k: (len(adj[k] - seen), pos[k]))]
        seen.add(walk[0])
        while True:
            nxt = [k for k in adj[walk[-1]] if k not in seen]
            if not nxt: break
            walk.append(min(nxt, key=lambda k: (len(adj[k] - seen), pos[k])))
            seen.add(walk[-1])
        walks.append(walk)
    return walks, [k for k in keys if k not in seen]

def columns_of(units, arrows, C=None):
    """The units in columns of about equal height, walks kept whole in a column where they fit, so
    files joined by an arrow sit one under another."""
    walks, rest = chain_order(units, arrows)
    by = {u.key: u for u in units}
    seq = [(k, i) for i, w in enumerate(walks) for k in w] + [(k, -1 - j) for j, k in enumerate(rest)]
    C = min(C or cols_for(len(seq)), len(seq))
    target = (sum(by[k].uh for k, _ in seq) + GY * (len(seq) - C)) / C
    cols, cur, h = [], [], 0
    for i, (k, walk) in enumerate(seq):
        u = by[k]
        boundary = not cur or seq[i - 1][1] != walk
        if cur and len(cols) < C - 1 and (h >= target or (boundary and h + u.uh > target * 1.15)):
            cols.append(cur)
            cur, h = [], 0
        cur.append(u)
        h += u.uh + GY
    cols.append(cur)
    return cols

LADDER = True
LADDER_GX = 240         # between a ladder's two columns, where its arrows run

def outer(u, side):
    """u with all its pills on one side."""
    groups, via, owner = u.right.groups + u.left.groups, u.right.via | u.left.via, u.right.owner
    cols = (Column(owner, groups, 'r', via), Column(owner, [], 'l')) if side == 'r' else (Column(owner, [], 'r'), Column(owner, groups, 'l', via))
    return Unit(u.title, u.text, u.w, u.nh, u.public, *cols, key=u.key, kind=u.kind)

LADDER_ORDER = 'split'

def ladder_of(units, arrows):
    """The units in a ladder's two columns: the walks along the arrows cut in two by height ('split'),
    or each walk's files alternating sides ('zigzag')."""
    by = {u.key: u for u in units}
    fixed = LADDER_FIX.get(frozenset(by))
    if fixed:
        return [by[k] for k in fixed[0]], [by[k] for k in fixed[1]]
    l, r = first_ladder(units, arrows)
    LAST_LADDERS[frozenset(by)] = ([u.key for u in l], [u.key for u in r])
    return l, r

LADDER_FIX, LAST_LADDERS, FRAME_FIX = {}, {}, {}

def first_ladder(units, arrows):
    walks, rest = chain_order(units, arrows)
    by = {u.key: u for u in units}
    seq = [k for w in walks for k in w] + rest
    if LADDER_ORDER == 'zigzag':
        l, r, hl, hr = [], [], 0, 0
        for w in walks + [[k] for k in rest]:
            for i, k in enumerate(w):
                side = (i % 2 == 0) == (hl <= hr) if i == 0 else not last
                last = side
                if side: l.append(by[k]); hl += by[k].uh + GY
                else: r.append(by[k]); hr += by[k].uh + GY
        if not r: r, l = l[-1:], l[:-1]
        return l, r
    hs = [by[k].uh + GY for k in seq]
    i = min(range(1, len(seq)), key=lambda i: abs(sum(hs[:i]) - sum(hs[i:])))
    l, r = [by[k] for k in seq[:i]], [by[k] for k in seq[i:]]
    inner = sorted({tuple(sorted((a, b), key=title_of)) for a, b in arrows if a in by and b in by and a != b}, key=lambda p: (title_of(p[0]), title_of(p[1])))
    ck = (tuple(sorted(by, key=title_of)), tuple(inner))
    if ck not in _ladders:
        _ladders[ck] = improve_ladder(l, r, inner) if len(seq) <= LADDER_SEARCH else ([u.key for u in l], [u.key for u in r])
    l, r = _ladders[ck]
    return [by[k] for k in l], [by[k] for k in r]

_ladders = {}
LADDER_SEARCH = 10      # a bigger ladder keeps its first split: the search takes minutes past a dozen files

def ladder_cost(l, r, inner):
    """What a ladder's own arrows cross (a note 10, a pill frame 1), then how uneven its columns are."""
    g = Grid(l + r, inner, ladder=(l, r))
    placed = g.place(0, 0)
    box = {u.key: Box(b.x, b.y - NOTE_HEADER, b.w, b.h + NOTE_HEADER, u.title) for u, b, _, _ in placed}
    frames = [Box(f.x, f.y - TITLE, f.w, f.h + TITLE, f.name) for _, _, _, fr in placed for f in fr]
    cost = 0
    for a, b in inner:
        c = crossings(box[a], box[b], [o for k, o in box.items() if k not in (a, b)], frames)
        cost += 10 * c[0] + c[1]
    return (cost, abs(g.ch[0] - g.ch[1]))

def improve_ladder(l, r, inner):
    """The columns, as keys, after moving files from one column (or place) to another, or swapping
    two, while that makes the ladder's own arrows cross less; as they are when they cross nothing."""
    cols = [list(l), list(r)]
    best = ladder_cost(*cols, inner)
    for _ in range(8):
        if best[0] == 0: break
        better = None
        n = [len(c) for c in cols]
        moves = [('move', c, i, d, j) for c in (0, 1) for i in range(n[c]) for d in (0, 1) for j in range(n[d] + (d != c))]
        moves += [('swap', c, i, d, j) for c in (0, 1) for i in range(n[c]) for d in (0, 1) for j in range(n[d]) if (c, i) < (d, j)]
        for kind, c, i, d, j in moves:
            t = [list(cols[0]), list(cols[1])]
            if kind == 'move':
                u = t[c].pop(i)
                t[d].insert(j, u)
            else:
                t[c][i], t[d][j] = t[d][j], t[c][i]
            if not t[0] or not t[1] or t == cols: continue
            cost = ladder_cost(*t, inner)
            if cost < best:
                better, best = t, cost
        if not better: break
        cols = better
    return [u.key for u in cols[0]], [u.key for u in cols[1]]

class Grid:
    """Units in columns, files joined by an arrow one under another where they can be, so the arrow
    runs down between them, clear of the pills beside them. Units with arrows between them make a
    ladder: two columns, the left one's pills on its left and its notes flush right, the right one's
    pills on its right, so arrows between the columns cross only the gap between them."""
    def __init__(self, units, arrows=(), ladder=None):
        keys = {u.key for u in units}
        self.ladder = LADDER and len(units) > 1 and any(a in keys and b in keys and a != b for a, b in arrows)
        if self.ladder:
            l, r = ladder or ladder_of(units, arrows)
            self.cols = [[outer(u, 'l') for u in l], [outer(u, 'r') for u in r]]
        else:
            self.cols = columns_of(units, arrows) if units else []
        self.units = [u for col in self.cols for u in col]
        self.lx = [max(u.lx for u in col) for col in self.cols]
        self.cw = [self.lx[i] + max(u.w + u.right.reach for u in col) for i, col in enumerate(self.cols)]
        self.ch = [sum(u.uh for u in col) + GY * (len(col) - 1) for col in self.cols]
        self.gx = LADDER_GX if self.ladder else GX
        self.w = sum(self.cw) + self.gx * (len(self.cols) - 1) if units else 0
        self.h = max(self.ch, default=0)

    def place(self, x0, y0):
        out, x = [], x0
        for ci, col in enumerate(self.cols):
            y = y0
            for u in col:
                nx = x + self.cw[ci] - u.w if self.ladder and ci == 0 else x + self.lx[ci]
                box = Box(nx, y + u.uh / 2 - u.nh / 2, u.w, u.nh, u.title)
                pr, fr = u.right.place(box)
                pl, fl = u.left.place(box)
                out.append((u, box, pr + pl, fr + fl))
                y += u.uh + GY
            x += self.cw[ci] + self.gx
        return out

SUB_ROW = 4             # a frame's subframes sit in a row, up to this many; more wrap into rows of about a root of them

def sub_rows(subs):
    if not subs:
        return []
    per = len(subs) if len(subs) <= SUB_ROW else math.ceil(math.sqrt(len(subs)))
    return [subs[i:i + per] for i in range(0, len(subs), per)]

class Frame:
    def __init__(self, title, units, subs, arrows=()):
        self.title, self.grid, self.subs = title, Grid(units, arrows), subs
        rows = sub_rows(subs)
        sw = max((sum(s.w for s in row) + GX * (len(row) - 1) for row in rows), default=0)
        sh = sum(max(s.h for s in row) for row in rows) + GY * (len(rows) - 1) if rows else 0
        self.w = math.ceil(2 * P + max(self.grid.w, sw))
        self.h = math.ceil(2 * P + self.grid.h + (SUB if units and subs else 0) + sh)

def walk_units(f):
    yield from f.grid.units
    for s in f.subs:
        yield from walk_units(s)

def layout_frame(fr, bx, by, parent, frames, notes):
    frames.append(dict(title=fr.title, parent=parent, bx=bx, by=by, w=fr.w, h=fr.h))
    for (u, box, pills, gframes) in fr.grid.place(bx + P, by + P):
        notes.append(dict(unit=u, box=box, holder=fr.title, hx=bx, hy=by, pills=pills, gframes=gframes))
    sy = by + P + fr.grid.h + (SUB if fr.grid.units else 0)
    for row in sub_rows(fr.subs):
        sx = bx + P
        for s in row:
            layout_frame(s, sx, sy, fr.title, frames, notes)
            sx += s.w + GX
        sy += max(s.h for s in row) + GY

def shelf(blocks, start_x, target_w, first_row_h):
    out, x, y, row_h = [], start_x, 0, first_row_h
    for b in blocks:
        if x > (start_x if y == 0 else 0) and x + b.w > target_w:
            x, y, row_h = 0, y + row_h + BGY, 0
        out.append((b, x, y))
        x += b.w + BGX
        row_h = max(row_h, b.h)
    return out

def plan_board(board, pilled=frozenset()):
    """Everything on a module's (or folder's) board, with the About note's top-left at (0, 0); the
    edges between its files in `pilled` go into pills."""
    M = measured()
    def height(t):
        if t not in M:
            raise SystemExit(f"no height measured for {t}: run gen2.py measure {BOARDS[board][0]}")
        return M[t]
    same, other = gen.edges_between(set(PROD))
    arrows = [(k, t) for k, t, _ in board_pairs(board) if (k, t) not in pilled]
    def unit(k):
        t = ftitle(k)
        pub = gen.is_public(k, other) or any(t2 == k for _, t2 in pilled)
        right, left = file_columns(k, other, sorted((t2 for k2, t2 in pilled if k2 == k), key=ftitle))
        return Unit(t, file_text(k), note_w(t, pub), height(t), pub, right, left, key=k)
    measured_about = height(about_title(board))
    about = Unit(about_title(board), about_text(board), ABOUT_W, gen2.about_height(board, M) if '@[' in about_text(board) else measured_about,
                 False, Column('', [], 'r'), Column('', [], 'l'))
    frames, notes = [], []
    spec = GROUPS.get(board)
    if board in FOLDER_BOARDS:
        units = [card_unit(f, pilled) for f in folder_boards(board)] + [unit(k) for k in board_files(board)]
        for (u, box, pills, gframes) in Grid(units, arrows).place(ABOUT_W + BGX, 0):
            notes.append(dict(unit=u, box=box, holder=None, hx=0, hy=0, pills=pills, gframes=gframes))
    elif spec:
        def build(g):
            title, names, subs = g
            return Frame(title, [unit(key_in(board, n)) for n in names if in_model(board, n)], [build(s) for s in subs], arrows)
        tops = [build(g) for g in spec]
        if board in FRAME_FIX:
            tops.sort(key=lambda f: FRAME_FIX[board].index(f.title))
        listed = [u.key for f in tops for u in walk_units(f)]
        missing = set(board_files(board)) - set(listed)
        if missing:
            raise SystemExit(f"{board}: the spec leaves out {sorted(ftitle(k) for k in missing)}")
        area = sum(f.w * f.h for f in tops) + ABOUT_W * about.nh
        target = max(max(f.w for f in tops) + ABOUT_W + BGX, math.sqrt(area * 1.7))
        for f, x, y in shelf(tops, ABOUT_W + BGX, target, about.nh):
            layout_frame(f, x, y, None, frames, notes)
    else:
        for (u, box, pills, gframes) in Grid([unit(k) for k in board_files(board)], arrows).place(ABOUT_W + BGX, 0):
            notes.append(dict(unit=u, box=box, holder=None, hx=0, hy=0, pills=pills, gframes=gframes))
    W = max([ABOUT_W] + [f['bx'] + f['w'] for f in frames] + [n['box'].x + n['box'].w + n['unit'].right.reach for n in notes])
    stage(notes, W + 2000)
    return about, frames, notes, same, other

_unknown = set()

def in_model(board, name):
    """Whether the model has a file the spec names. A name it lacks (a file the model was analyzed without)
    is left out, and said once."""
    if (board, name) in _unknown:
        return False
    try:
        key_in(board, name)
        return True
    except SystemExit:
        _unknown.add((board, name))
        print(f"  {board}: the spec names {name}, which the model doesn't have; left out", flush=True)
        return False

def stage(notes, x0):
    """Where each note goes first, right of the board from x0: shelved, with room for draw's lists."""
    x = y = rowh = 0
    for n in notes:
        u = n['unit']
        if x and x + u.uw0 > STAGE_W:
            x, y, rowh = 0, y + rowh + STAGE_GAP, 0
        n['stage'] = Box(x0 + x + u.lx0, y + (u.uh0 - u.nh) / 2, u.w, u.nh, u.title)
        x += u.uw0 + STAGE_GAP
        rowh = max(rowh, u.uh0)

TEMP_TAGS = ('zz-p', 'zz-q')    # the temporary frames' titles, round by round

def temps(notes, prefix, rnd=1):
    """Each temporary frame of a round (Column.moves): its title, where it's drawn (the first round's in the
    staging area, the second's where the first left its pills), where it goes to put its pills home, and its note."""
    out, i = [], 0
    for n in notes:
        u = n['unit']
        for col in (u.right, u.left):
            for b0, b1 in col.moves(n['stage'], n['box'])[rnd - 1]:
                i += 1
                out.append((f"{TEMP_TAGS[rnd - 1]} {prefix} {i}", b0, b1, n))
    return out

def check_plan(board, about, frames, notes):
    """Nothing overlaps (group frames with their titles), and every group frame is 40 inside its holder."""
    boxes = [Box(0, 0, ABOUT_W, about.nh, about.title)]
    for n in notes:
        boxes.append(n['box'])
        boxes += [Box(f.x, f.y - TITLE, f.w, f.h + TITLE, f.name) for f in n['gframes']]
    problems = [f"{a.name} overlaps {b.name}" for i, a in enumerate(boxes) for b in boxes[i + 1:] if a.overlaps(b)]
    fr = {f['title']: f for f in frames}
    for n in notes:
        if not n['holder']: continue
        f = fr[n['holder']]
        for g in n['gframes'] + [n['box']]:
            if g.x < f['bx'] + 40 or g.y < f['by'] + 40 or g.x + g.w > f['bx'] + f['w'] - 40 or g.y + g.h > f['by'] + f['h'] - 40:
                problems.append(f"{g.name} is within 40 of {f['title']}'s edge")
    titles = [g.name for n in notes for g in n['gframes']]
    dup = [t for t, c in collections.Counter(titles).items() if c > 1]
    if dup: problems.append(f"titles twice: {dup[:5]}")
    long = [t for t in titles if len(t) > 80]
    if long: problems.append(f"titles over 80: {long[:3]}")
    return problems

# ---- which arrows between a board's files stay arrows ----------------------------------------------

NOTE_HEADER = 30        # a note's title pill, above it

def board_obstacles(about, notes):
    """The About note, each note with its title, and each group frame with its title. An arrow may pass
    between a note and its frames, or between two of them, as the arrows to its pills do."""
    obs = {'': Box(0, 0, ABOUT_W, about.nh, about.title)}
    frames = []
    for n in notes:
        b = n['box']
        obs[n['unit'].title] = Box(b.x, b.y - NOTE_HEADER, b.w, b.h + NOTE_HEADER, n['unit'].title)
        frames += [Box(f.x, f.y - TITLE, f.w, f.h + TITLE, f.name) for f in n['gframes']]
    return obs, frames

def clear_bend(a, b, others):
    """The smallest bend, to 0.14 of the arrow's length and 240, that takes the arrow from box a to box b
    clear of `others` (inflated 10), or None."""
    L = math.hypot(b.c[0] - a.c[0], b.c[1] - a.c[1])
    n = max(48, int(L / 8))
    inflated = [o.inflate(10) for o in others]
    def clear(bend):
        pts = [p for p in arc_points(a.c, b.c, bend, n) if not a.contains(p) and not b.contains(p)]
        return not any(o.contains(p) for o in inflated for p in pts)
    if clear(0):
        return 0
    for f in BENDS:
        mag = min(BEND_CAP, max(40, f * L))
        for sign in (1, -1):
            if clear(sign * mag):
                return round(sign * mag)
    return None

BENDS, BEND_CAP = (0.06, 0.1, 0.14, 0.2), 320
ALLOW = 'frames'        # what an arrow may cross: 'none', 'frames' (pill frames, no note), 'note' (one note too), 'all'

def crossings(a, b, notes_, frames_):
    """(notes, pill frames, bend): the fewest an arrow from box a to box b crosses, notes counting
    most, at the smallest bend that does it."""
    L = math.hypot(b.c[0] - a.c[0], b.c[1] - a.c[1])
    n = max(48, int(L / 8))
    ins = [o.inflate(10) for o in notes_]
    fs = [o.inflate(10) for o in frames_]
    best = None
    for bend in [0] + [sign * min(BEND_CAP, max(40, f * L)) for f in BENDS for sign in (1, -1)]:
        pts = [p for p in arc_points(a.c, b.c, bend, n) if not a.contains(p) and not b.contains(p)]
        c = (sum(1 for o in ins if any(o.contains(p) for p in pts)), sum(1 for o in fs if any(o.contains(p) for p in pts)))
        if best is None or c[0] * 10 + c[1] < best[0] * 10 + best[1]:
            best = (c[0], c[1], round(bend))
        if c == (0, 0):
            break
    return best

def allowed(c):
    return {'none': c[:2] == (0, 0), 'frames': c[0] == 0, 'note': c[0] <= 1, 'all': True}[ALLOW]

def board_pairs(board):
    """The edges between a board's files (on a module's with folder boards, its folders, then its own files), a
    pair a line: (a, b, both) with a's title first when both."""
    out = []
    if board in FOLDER_BOARDS:
        W = folder_uses(board)
        done = set()
        for a, b in sorted(W):
            if (a, b) in done: continue
            both = (b, a) in W
            done |= {(a, b), (b, a)}
            out.append((a, b, both))
    return out + file_pairs(board)

def file_pairs(board):
    same, _ = gen.edges_between(set(PROD))
    files = set(board_files(board))
    done, out = set(), []
    for k in sorted(files, key=ftitle):
        for t in sorted(set(same.get(k, [])), key=ftitle):
            if (k, t) in done or t not in files: continue
            both = k in same.get(t, [])
            done |= {(k, t), (t, k)}
            out.append((k, t, both))
    return out

def arrow_of(about, notes, k, t):
    """The bend for the arrow from k to t, or None when it would cross more than ALLOW lets it."""
    c = cross_of(about, notes, k, t)
    return c[2] if allowed(c) else None

def cross_of(about, notes, k, t):
    obs, fans = board_obstacles(about, notes)
    a, b = obs[title_of(k)], obs[title_of(t)]
    return crossings(a, b, [o for key, o in obs.items() if key not in (title_of(k), title_of(t))], fans)

import heuristic

def chosen_references(board):
    """The uses the heuristic draws through pills (heuristic-report.md): every use of a hub,
    and every arrow two stronger ones already relay."""
    if board in FOLDER_BOARDS:
        W = folder_uses(board)
        cards = set(heuristic.references_of(folder_boards(board), set(W), lambda a, b: W.get((a, b), 0), title=str))
        return cards | set(heuristic.references(board))
    return set(heuristic.references(board))

_decided = {}
BOARD_SEARCH = True
_searched = set()
SEARCH_FILE = os.path.join(RUNS, 'v9-search.json')

def search_stamp(board):
    """What a board's search was run against: its frames, its uses and its notes' heights."""
    M = measured()
    return hashlib.sha1(json.dumps([GROUPS.get(board), [(ftitle(k), ftitle(t), both) for k, t, both in board_pairs(board)],
                                    [M.get(ftitle(k)) for k in board_files(board)]]).encode()).hexdigest()

def saved_searches():
    try:
        return json.load(open(SEARCH_FILE))
    except (OSError, ValueError):
        return {}

def board_cost(board, chosen):
    """What a board's chosen arrows cost where the layout puts them: how many it would have to make
    pills, what they cross (a note 10, a pill frame 1), and how long they are."""
    about, frames, notes, _, _ = plan_board(board, frozenset(chosen))
    box = {n['unit'].key: n['box'] for n in notes}
    fails = cost = length = 0
    for k, t, _ in board_pairs(board):
        if (k, t) in chosen: continue
        c = cross_of(about, notes, k, t)
        fails += not allowed(c)
        cost += 10 * c[0] + c[1]
        length += math.hypot(box[k].c[0] - box[t].c[0], box[k].c[1] - box[t].c[1])
    return (fails, cost, round(length / 400))

def board_search(board):
    """Moves files linked across frames within their frames' ladders, flips ladders, and swaps
    neighbouring frames, while that lowers board_cost; the result is kept in LADDER_FIX and FRAME_FIX."""
    chosen = chosen_references(board)
    spec = GROUPS.get(board)
    if not spec or board in FOLDER_BOARDS:
        return
    saved = saved_searches().get(board)
    if saved and saved.get('stamp') == search_stamp(board):
        if saved['order']:
            FRAME_FIX[board] = saved['order']
        for l, r in saved['ladders']:
            l, r = [tuple(k) for k in l], [tuple(k) for k in r]
            LADDER_FIX[frozenset(l + r)] = (l, r)
        return
    mine = set(board_files(board))
    LAST_LADDERS.clear()
    best = board_cost(board, chosen)
    for ks, lr in LAST_LADDERS.items():
        LADDER_FIX[ks] = lr
    of = {k: ks for ks in LADDER_FIX for k in ks}
    pairs = [(k, t) for k, t, _ in board_pairs(board) if (k, t) not in chosen]
    across = sorted({k for a, b in pairs for k in (a, b) if a in of and b in of and of[a] != of[b]}, key=title_of)
    def attempt(change, undo):
        nonlocal best
        change()
        c = board_cost(board, chosen)
        if c < best:
            best = c
            return True
        undo()
        return False
    for _ in range(3):
        moved = False
        for ks in [ks for ks in LADDER_FIX if ks <= mine]:     # another board's ladders don't change this one's cost
            l, r = LADDER_FIX[ks]
            moved |= attempt(lambda: LADDER_FIX.__setitem__(ks, (r, l)), lambda: LADDER_FIX.__setitem__(ks, (l, r)))
        for k in across:
            ks = of[k]
            l, r = LADDER_FIX[ks]
            cols = [list(l), list(r)]
            for d in (0, 1):
                for j in range(len(cols[d]) + 1):
                    ci = 0 if k in cols[0] else 1
                    if j > len(cols[d]) - (d == ci): continue
                    t = [list(cols[0]), list(cols[1])]
                    t[ci].remove(k)
                    t[d].insert(j, k)
                    if not t[0] or not t[1] or t == cols: continue
                    old = LADDER_FIX[ks]
                    if attempt(lambda: LADDER_FIX.__setitem__(ks, (t[0], t[1])), lambda: LADDER_FIX.__setitem__(ks, old)):
                        moved = True
                        cols = t
        titles = [g[0] for g in spec]
        order = FRAME_FIX.get(board, titles)
        for i in range(len(order) - 1):
            o2 = order[:i] + [order[i + 1], order[i]] + order[i + 2:]
            old = FRAME_FIX.get(board)
            if attempt(lambda: FRAME_FIX.__setitem__(board, o2), lambda: FRAME_FIX.__setitem__(board, old) if old else FRAME_FIX.pop(board, None)):
                moved = True
                order = o2
        if not moved: break
    print(f"  {board}: searched to {best} (pills forced, crossing cost, length/400)", flush=True)
    data = saved_searches()
    data[board] = dict(stamp=search_stamp(board), order=FRAME_FIX.get(board), ladders=[[[list(k) for k in l], [list(k) for k in r]] for ks, (l, r) in LADDER_FIX.items() if ks <= mine])
    json.dump(data, open(SEARCH_FILE, 'w'), indent=0)

def decide_board(board):
    """Which of a board's uses go into pills: the heuristic's, then any arrow it keeps that clears
    nothing after a small bend; to a fixed point, then back to arrows where the layout leaves room,
    nearest first."""
    if board in _decided:
        return _decided[board]
    if BOARD_SEARCH and board not in _searched:
        _searched.add(board)
        board_search(board)
    pairs = board_pairs(board)
    chosen = chosen_references(board)
    def as_pills(p):
        k, t, both = p
        return {(k, t), (t, k)} if both else {(k, t)}
    def dist(notes, k, t):
        box = {n['unit'].key: n['box'] for n in notes}
        return math.hypot(box[k].c[0] - box[t].c[0], box[k].c[1] - box[t].c[1])
    pilled = set(chosen)
    for _ in range(20):
        about, frames, notes, _, _ = plan_board(board, frozenset(pilled))
        now = set(pilled)
        for p in pairs:
            if (p[0], p[1]) not in now and arrow_of(about, notes, p[0], p[1]) is None:
                now |= as_pills(p)
        if now == pilled: break
        pilled = now
    about, frames, notes, _, _ = plan_board(board, frozenset(pilled))
    for p in sorted([p for p in pairs if (p[0], p[1]) in pilled and (p[0], p[1]) not in chosen], key=lambda p: dist(notes, p[0], p[1])):
        if arrow_of(about, notes, p[0], p[1]) is None: continue
        trial = pilled - as_pills(p)
        ta, tf, tn, _, _ = plan_board(board, frozenset(trial))
        if all(arrow_of(ta, tn, q[0], q[1]) is not None for q in pairs if (q[0], q[1]) not in trial):
            pilled, about, notes = trial, ta, tn
    _decided[board] = frozenset(pilled)
    return _decided[board]

def plan_for(board):
    return plan_board(board, decide_board(board))

# ---- drawing a board ------------------------------------------------------------------------------

def note_stmt(u, place, holder):
    if u.kind == 'subboard':
        return f"subboard {q(u.title)} in {q(holder)} {place} size: {u.w}x{u.nh} public: true"
    parts = [f"sticky-note {q(u.title)}"] + ([f"in {q(holder)}"] if holder else []) + [place, f"size: {u.w}x{math.ceil(u.nh)}"]
    if u.public: parts.append("public: true")
    parts.append(f"text: {text_lit(u.text)}")
    return ' '.join(parts)

def label(board):
    """A board's name in run marks, script files and temporary titles: its title with '_' for '/', made unique."""
    if not _labels:
        _labels[None] = 'root'      # the root's own
        for b in [m for m in PROD if m in FOLDER_BOARDS] + gen.boards_for(PROD):
            base, n = b.replace('/', '_'), 1
            while (base if n == 1 else f"{base}-{n}") in _labels.values():
                n += 1
            _labels[b] = base if n == 1 else f"{base}-{n}"
    return _labels[board]

_labels = {}

def step_boards(boards):
    for board in boards:
        about, frames, notes, _, _ = plan_for(board)
        problems = check_plan(board, about, frames, notes)
        if problems:
            print(f"{board}: the plan has problems:\n  " + '\n  '.join(problems[:20])); sys.exit(1)
        A = about.title
        lines = [f"sticky-note {q(A)} in {q(board)} size: {ABOUT_W}x{math.ceil(about.nh)} text: {text_lit(about.text)}"]
        lines += [f"frame {q(f['title'])} in {q(board)} size: {f['w']}x{f['h']} {at(A, f['bx'], f['by'])}" for f in frames if f['parent'] is None]
        draw(f'v9-board-{label(board)}-frames', '\n'.join(lines) + '\n')
        fr = {f['title']: f for f in frames}
        level = {f['title']: 0 for f in frames if f['parent'] is None}
        pending, depth = [f for f in frames if f['parent'] is not None], 1
        while pending:
            now = [f for f in pending if level.get(f['parent']) == depth - 1]
            lines = [f"frame {q(f['title'])} in {q(f['parent'])} size: {f['w']}x{f['h']} "
                     f"{at(f['parent'], f['bx'] - fr[f['parent']]['bx'], f['by'] - fr[f['parent']]['by'])}" for f in now]
            draw(f'v9-board-{label(board)}-frames-{depth + 1}', '\n'.join(lines) + '\n')
            for f in now: level[f['title']] = depth
            pending = [f for f in pending if f not in now]
            depth += 1
        lines = [note_stmt(n['unit'], at(A, n['stage'].x, n['stage'].y), board) for n in notes]
        draw(f'v9-board-{label(board)}-notes', '\n'.join(lines) + '\n')

def step_edges(boards):
    """Pills, then the arrows that stay arrows, bent as decided."""
    for board in boards:
        about, frames, notes, same, other = plan_for(board)
        pilled = decide_board(board)
        lines = []
        for n in notes:
            u = n['unit']
            lines += u.right.edges(u.title) + u.left.edges(u.title)
        for k, t, both in board_pairs(board):
            if (k, t) in pilled: continue
            bend = arrow_of(about, notes, k, t)
            lines.append(f"edge {q(title_of(k))} {'<->' if both else '->'} {q(title_of(t))}" + (f" bend: {bend}" if bend else ''))
        if lines:
            draw(f'v9-edges-{label(board)}', '\n'.join(lines) + '\n')

def size(b):
    return f"size: {math.ceil(b.w)}x{math.ceil(b.h)}"

def group_stmt(g, holder, hx, hy, anchor=None):
    place = at(anchor or holder, g.x - hx, g.y - hy)
    return f"frame {q(g.name)} in {q(holder)} {place} {size(g)} overlap: allow"

def step_groups(boards):
    for board in boards:
        about, frames, notes, _, _ = plan_for(board)
        lines = []
        for n in notes:
            for g in n['gframes']:
                lines.append(group_stmt(g, n['holder'], n['hx'], n['hy']) if n['holder'] else group_stmt(g, board, 0, 0, about.title))
        if lines:
            draw(f'v9-groups-{label(board)}', '\n'.join(lines) + '\n')

def place_in(board, about, n, b):
    """Where box b goes, as `in` and an exact offset: in the note's holder, or on the board."""
    if n['holder']:
        return f"in {q(n['holder'])} {at(n['holder'], b.x - n['hx'], b.y - n['hy'])}"
    return f"in {q(board)} {at(about.title, b.x, b.y)}"

def step_temps(boards, rnd=1):
    """A round's temporary frames, drawn over the pills they carry (`overlap: allow` takes them in): the first
    round's in the staging area, the second's in the notes' holders, where the first left the pills."""
    for board in boards:
        about, _, notes, _, _ = plan_for(board)
        lines = [f"frame {q(t)} {f'in {q(board)} {at(about.title, b0.x, b0.y)}' if rnd == 1 else place_in(board, about, n, b0)} "
                 f"{size(b0)} overlap: allow" for t, b0, b1, n in temps(notes, label(board), rnd)]
        if lines:
            draw(f'v9-temps{rnd if rnd > 1 else ""}-{label(board)}', '\n'.join(lines) + '\n')

def step_pack(boards, rnd=1):
    for board in boards:
        about, _, notes, _, _ = plan_for(board)
        lines = [f"frame {q(t)} {place_in(board, about, n, b1)}" for t, b0, b1, n in temps(notes, label(board), rnd)]
        if lines:
            draw(f'v9-pack{rnd if rnd > 1 else ""}-{label(board)}', '\n'.join(lines) + '\n')

def step_untemp(boards, rnd=1):
    for board in boards:
        _, _, notes, _, _ = plan_for(board)
        lines = [f"delete {q(t)}" for t, _, _, _ in temps(notes, label(board), rnd)]
        if lines:
            draw(f'v9-untemp{rnd if rnd > 1 else ""}-{label(board)}', '\n'.join(lines) + '\n')

def step_home(boards):
    for board in boards:
        about, _, notes, _, _ = plan_for(board)
        lines = [f"{n['unit'].kind} {q(n['unit'].title)} {place_in(board, about, n, n['box'])}" for n in notes]
        if lines:
            draw(f'v9-home-{label(board)}', '\n'.join(lines) + '\n')

# ---- the root -------------------------------------------------------------------------------------

EDGES = [(m, d) for m in PROD for d in MODS[m]['deps']]

def balanced_rows(ms, per=7):
    R = math.ceil(len(ms) / per)
    n = math.ceil(len(ms) / R)
    return [ms[i:i + n] for i in range(0, len(ms), n)]

class RootLayout:
    def __init__(self, pilled):
        bands = gen2.band_order()
        pos = {m: (bi, i) for bi, (_, ms) in enumerate(bands) for i, m in enumerate(ms)}
        self.cols = {}
        for m in PROD:
            ts = sorted((d for d in MODS[m]['deps'] if (m, d) in pilled), key=lambda d: pos[d])
            groups = [(short(layer), [d for d in ts if LAYER_OF[d] == layer]) for layer, _ in BANDS]
            self.cols[m] = split(m, [(g, ps) for g, ps in groups if ps], ROOT_SPLIT)
        self.size = {}
        for m in PROD:
            r, l = self.cols[m]
            self.size[m] = (l.reach, l.reach + SUB_W + r.reach, max(SUB_H, r.ext, l.ext))
        self.bands, self.card, self.pills, self.gframes = [], {}, {}, {}
        for title, ms in bands:
            rows = balanced_rows(ms)
            rw = [sum(self.size[m][1] for m in row) + UGX * (len(row) - 1) for row in rows]
            rh = [max(self.size[m][2] for m in row) for row in rows]
            self.bands.append(dict(title=title, rows=rows, rw=rw, rh=rh, w=math.ceil(2 * P + max(rw)), h=math.ceil(2 * P + sum(rh) + RGY * (len(rows) - 1))))
        maxw = max(b['w'] for b in self.bands)
        x0, y = ANCHOR_W + 160, 0
        for b in self.bands:
            b['x'], b['y'] = round(x0 + (maxw - b['w']) / 2), y
            ry = y + P
            for row, rw, rh in zip(b['rows'], b['rw'], b['rh']):
                ux = b['x'] + (b['w'] - rw) / 2
                for m in row:
                    lx, uw, uh = self.size[m]
                    c = self.card[m] = Box(round(ux + lx), round(ry + rh / 2 - SUB_H / 2), SUB_W, SUB_H, m)
                    r, l = self.cols[m]
                    pr, fr = r.place(c)
                    pl, fl = l.place(c)
                    self.pills[m], self.gframes[m] = pr + pl, fr + fl
                    ux += uw + UGX
                ry += rh + RGY
            y += b['h'] + BANDGAP
        self.band_of = {m: b for b in self.bands for row in b['rows'] for m in row}
        # first, each card right of the bands, with room for draw's lists
        x0 = max(b['x'] + b['w'] for b in self.bands) + 2000
        x = y = rowh = 0
        self.stage = {}
        for m in PROD:
            r, l = self.cols[m]
            uw0, uh0 = l.reach0 + SUB_W + r.reach0, max(SUB_H, r.L0, l.L0) + 2 * TITLE
            if x and x + uw0 > STAGE_W:
                x, y, rowh = 0, y + rowh + STAGE_GAP, 0
            self.stage[m] = Box(x0 + x + l.reach0, y + (uh0 - SUB_H) / 2, SUB_W, SUB_H, m)
            x += uw0 + STAGE_GAP
            rowh = max(rowh, uh0)

    def obstacles(self):
        cards = {m: Box(c.x, c.y - HEADER, c.w, c.h + HEADER, m) for m, c in self.card.items()}
        fans = []
        for m, c in self.card.items():
            for side in ('r', 'l'):
                fs = [f for f in self.gframes[m] if (f.x > c.x) == (side == 'r')]
                if not fs: continue
                top, bot = min(min(f.y for f in fs) - TITLE, c.y), max(max(f.y + f.h for f in fs), c.y + c.h)
                x0, x1 = (c.x + c.w, max(f.x + f.w for f in fs)) if side == 'r' else (min(f.x for f in fs), c.x)
                fans.append(Box(x0, top, x1 - x0, bot - top, f"{m}:{side}"))
        return cards, fans

    def arrow(self, m, d):
        """The bend that clears the arrow from m to d, or None when no small one does."""
        cards, fans = self.obstacles()
        others = [o.inflate(10) for k, o in cards.items() if k not in (m, d)] + [f.inflate(10) for f in fans]
        a, b = cards[m], cards[d]
        L = math.hypot(b.c[0] - a.c[0], b.c[1] - a.c[1])
        n = max(48, int(L / 8))
        def clear(bend):
            pts = [p for p in arc_points(a.c, b.c, bend, n) if not a.contains(p) and not b.contains(p)]
            return not any(o.contains(p) for o in others for p in pts)
        if clear(0):
            return 0
        for f in (0.06, 0.1, 0.14):
            mag = min(240, max(40, f * L))
            for sign in (1, -1):
                if clear(sign * mag):
                    return round(sign * mag)
        return None

def root_decide():
    def dist(lay, m, d):
        a, b = lay.card[m].c, lay.card[d].c
        return math.hypot(a[0] - b[0], a[1] - b[1])
    pilled = set()
    for _ in range(20):
        lay = RootLayout(pilled)
        now = set(pilled) | {(m, d) for m, d in EDGES if (m, d) not in pilled and lay.arrow(m, d) is None}
        kept = collections.defaultdict(list)
        for m, d in EDGES:
            if (m, d) not in now: kept[d].append(m)
        for d, ms in kept.items():
            now |= {(m, d) for m in sorted(ms, key=lambda m: dist(lay, m, d))[CAP:]}
        if now == pilled: break
        pilled = now
    lay = RootLayout(pilled)
    for m, d in sorted(pilled, key=lambda e: (dist(lay, *e), e)):     # ties in the same order in every process
        trial = pilled - {(m, d)}
        if sum(1 for x, y in EDGES if y == d and (x, y) not in trial) > CAP: continue
        tl = RootLayout(trial)
        if all(tl.arrow(x, y) is not None for x, y in EDGES if (x, y) not in trial):
            pilled, lay = trial, tl
    return pilled, lay

def root_report(pilled, lay):
    kept = [e for e in EDGES if e not in pilled]
    W = max(b['x'] + b['w'] for b in lay.bands)
    H = lay.bands[-1]['y'] + lay.bands[-1]['h']
    print(f"root: {len(kept)} arrows, {len(pilled)} pills in {sum(len(v) for v in lay.gframes.values())} group frames; {W} x {H}")

def root_bands(lay):
    """The anchor and the layer bands. They name no shape already drawn, so they go on the board the window
    shows: the window goes to the root first."""
    gen.canvas('show', '--board', gen.BOARD, '--root')
    lines = [f"sticky-note {q(ANCHOR)} size: {ANCHOR_W}x{ANCHOR_W}"]
    lines += [f"frame {q(b['title'])} size: {b['w']}x{b['h']} {at(ANCHOR, b['x'], b['y'])}" for b in lay.bands]
    saved = gen.EXPECTED
    gen.EXPECTED = saved + ('was nudged wholly in or out',)
    try:
        draw('v9-root-1-bands', '\n'.join(lines) + '\n')
    finally:
        gen.EXPECTED = saved

def root_modules(lay):
    draw('v9-root-2-modules', '\n'.join(f"subboard {q(m)} {at(ANCHOR, lay.stage[m].x, lay.stage[m].y)} size: {SUB_W}x{SUB_H} public: true"
                                         for m in PROD) + '\n')

def root_temps(lay, rnd=1):
    """Each temporary frame of a round on the root, as temps() gives a board's."""
    out, i = [], 0
    for m in PROD:
        for col in lay.cols[m]:
            for b0, b1 in col.moves(lay.stage[m], lay.card[m])[rnd - 1]:
                i += 1
                out.append((f"{TEMP_TAGS[rnd - 1]} root {i}", b0, b1, m))
    return out

def root_in_band(lay, m, b):
    band = lay.band_of[m]
    return f"in {q(band['title'])} {at(band['title'], b.x - band['x'], b.y - band['y'])}"

def root_edges(pilled, lay):
    lines = []
    for m in PROD:
        r, l = lay.cols[m]
        lines += r.edges(m, via=True) + l.edges(m, via=True)
    lines += [f"edge {q(m)} -> {q(d)} bend: {lay.arrow(m, d)}" for m, d in EDGES if (m, d) not in pilled]
    draw('v9-root-3-edges', '\n'.join(lines) + '\n')

def root_temps_step(pilled, lay):
    tt = root_temps(lay)
    draw('v9-root-4-temps', '\n'.join(f"frame {q(t)} {at(ANCHOR, b0.x, b0.y)} {size(b0)} overlap: allow" for t, b0, b1, m in tt) + '\n')

def root_pack(pilled, lay):
    draw('v9-root-5-pack', '\n'.join(f"frame {q(t)} {root_in_band(lay, m, b1)}" for t, b0, b1, m in root_temps(lay)) + '\n')

def root_untemp(pilled, lay):
    draw('v9-root-6-untemp', '\n'.join([f"delete {q(t)}" for t, _, _, _ in root_temps(lay)] + [f"delete {q(ANCHOR)}"]) + '\n')

def root_temps2(pilled, lay):
    """The second round's frames, in the bands, where the first left the pills: the anchor's gone by then."""
    tt = root_temps(lay, 2)
    if tt:
        draw('v9-root-6a-temps2', '\n'.join(f"frame {q(t)} {root_in_band(lay, m, b0)} {size(b0)} overlap: allow" for t, b0, b1, m in tt) + '\n')

def root_pack2(pilled, lay):
    tt = root_temps(lay, 2)
    if tt:
        draw('v9-root-6b-pack2', '\n'.join(f"frame {q(t)} {root_in_band(lay, m, b1)}" for t, b0, b1, m in tt) + '\n')

def root_untemp2(pilled, lay):
    tt = root_temps(lay, 2)
    if tt:
        draw('v9-root-6c-untemp2', '\n'.join(f"delete {q(t)}" for t, _, _, _ in tt) + '\n')

def root_groups(pilled, lay):
    lines = []
    for m in PROD:
        b = lay.band_of[m]
        lines += [group_stmt(g, b['title'], b['x'], b['y']) for g in lay.gframes[m]]
    draw('v9-root-7-groups', '\n'.join(lines) + '\n')

def root_home(pilled, lay):
    draw('v9-root-8-home', '\n'.join(f"subboard {q(m)} {root_in_band(lay, m, lay.card[m])}" for m in PROD) + '\n')

ROOT_STEPS = dict(edges=root_edges, temps=root_temps_step, pack=root_pack, untemp=root_untemp, temps2=root_temps2, pack2=root_pack2,
                  untemp2=root_untemp2, groups=root_groups, home=root_home)

# ---- everything ----------------------------------------------------------------------------------

def all_boards():
    return gen.boards_for(PROD)

def step_reset():
    """Everything at the root, so every board under it, and the marks of what was drawn; the window goes to
    the root first, since a board the window shows can't be deleted. Only what's there is deleted: a delete
    of a title that isn't there refuses the whole script."""
    gen.canvas('show', '--board', gen.BOARD, '--root')
    found = gen.canvas('query', '--board', gen.BOARD, '--limit', '10000', 'subboard, frame, sticky-note')
    if found['count'] > len(found['rows']):
        raise SystemExit(f"reset: {found['count']} shapes, more than a query lists")
    here = {r['title']: r['kind'] for r in found['rows'] if r.get('board') == 'root' and r.get('title')}
    cards = sorted(t for t, kind in here.items() if kind == 'subboard')
    # an import's pill goes with its edge, and is left standing for nothing if its module goes first
    pairs = [(a, b) for a in cards for b in cards if a != b]
    rc, r = cli('\n'.join(f'edge {q(a)} -> {q(b)}' for a, b in pairs) + '\n', dry=True) if pairs else (0, {})
    if 'error' in r:
        raise SystemExit(f"reset: the root's edges can't be listed: {r['error']}")
    on_board = {c['line'] for c in r.get('changes', []) if c.get('kind') == 'arrow' and c.get('did') == 'unchanged'}
    lines = [f'delete edge {q(a)} -> {q(b)}' for i, (a, b) in enumerate(pairs) if i + 1 in on_board]
    lines += [f'delete {q(t)}' for t, kind in sorted(here.items()) if kind == 'frame' and (' (' in t or t.startswith(tuple(f'{tag} ' for tag in TEMP_TAGS)))]
    lines += [f'delete {q(t)}' for t in [m for _, ms in BANDS for m in ms] if here.get(t) == 'subboard']
    lines += [f'delete {q(t)}' for t, _ in BANDS if here.get(t) == 'frame']
    lines += [f'delete {q(t)}' for t in (ANCHOR, LEGEND) if here.get(t) == 'sticky-note']
    if lines:
        rc, r = cli('\n'.join(lines) + '\n', dry=False)
        if 'error' in r:
            raise SystemExit(f"reset refused: {r['error']}")
        print(f"deleted: {len(r['changes'])} rows")
    for f in os.listdir(RUNS):
        if f.startswith(('drawn-', 'v9-done-')):
            os.remove(os.path.join(RUNS, f))

def drawn_boards():
    """Every board but the root: the boards of the modules with folder boards, then each module's (or its
    folders')."""
    return [m for m in PROD if m in FOLDER_BOARDS] + all_boards()

def step_plan():
    bad = 0
    titles = collections.Counter()
    for board in drawn_boards():
        about, frames, notes, _, _ = plan_for(board)
        pairs = board_pairs(board)
        chosen, pilled = chosen_references(board), decide_board(board)
        wanted = sum(1 for k, t, _ in pairs if (k, t) not in chosen)
        kept = sum(1 for k, t, _ in pairs if (k, t) not in pilled)
        print(f"  {board:<20} {kept:>3} of {len(pairs):>3} arrows stay ({wanted} chosen)")
        problems = check_plan(board, about, frames, notes)
        if problems:
            bad += 1
            print(f"{board}: " + '; '.join(problems[:6]))
        titles.update([about.title] + [f['title'] for f in frames] + [n['unit'].title for n in notes]
                      + [g.name for n in notes for g in n['gframes']])
    pilled, lay = root_decide()
    titles.update([b['title'] for b in lay.bands] + list(PROD) + [f.name for m in PROD for f in lay.gframes[m]])
    twice = [t for t, c in titles.items() if c > 1]
    print(f"{len(drawn_boards())} boards planned, {bad} with problems; {len(titles)} titles, "
          + (f"twice: {twice[:8]}" if twice else "each once"))

def once(name, fn):
    mark = os.path.join(RUNS, f'v9-done-{name}')
    if os.path.exists(mark): return
    fn()
    open(mark, 'w').write('')

STEPS = dict(edges=step_edges, temps=step_temps, pack=step_pack, untemp=step_untemp,
             temps2=lambda b: step_temps(b, 2), pack2=lambda b: step_pack(b, 2), untemp2=lambda b: step_untemp(b, 2),
             groups=step_groups, home=step_home)

def step_all():
    pilled, lay = root_decide()
    root_report(pilled, lay)
    once('reset', step_reset)
    once('root-bands', lambda: root_bands(lay))
    once('root-modules', lambda: root_modules(lay))
    for b in drawn_boards():
        once(f'boards-{label(b)}', lambda b=b: step_boards([b]))
    for b in drawn_boards():
        for name, fn in STEPS.items():
            once(f'{name}-{label(b)}', lambda b=b, fn=fn: fn([b]))
    for name, fn in ROOT_STEPS.items():
        once(f'root-{name}', lambda fn=fn: fn(pilled, lay))
    once('about-pad', lambda: gen2.step_about_pad(PROD))

if __name__ == '__main__':
    step, args = sys.argv[1], sys.argv[2:]
    if step == 'all':
        step_all()
    elif step == 'plan':
        step_plan()
        pilled, lay = root_decide()
        root_report(pilled, lay)
    elif step == 'reset':
        step_reset()
    elif step == 'boards' or step in STEPS:
        boards = ([m for m in args if m in FOLDER_BOARDS] + gen.boards_for(args)) if args else drawn_boards()
        (step_boards if step == 'boards' else STEPS[step])(boards)
