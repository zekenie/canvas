#!/usr/bin/env python3
"""The model the digest is made from, and each note's text.

A project is a directory (PROJECT, else this one) holding model.json, which a reader writes (README.md has its
format), and, where the code doesn't say enough, spec.py: what isn't there, or names what the code no longer has,
is worked out (defaults.py) and said in WARNINGS."""
import importlib.util, json, os, re, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
PROJECT = os.path.abspath(os.path.expanduser(os.environ.get('PROJECT', HERE)))

model = json.load(open(os.path.join(PROJECT, 'model.json')))
MODS = {m['name']: m for m in model['modules']}
PROD = [m['name'] for m in model['modules'] if not m['test']]
FILES = {(f['module'], f['rel']): f for f in model['files'] if f['module'] in PROD}
for m in PROD:      # a module's imports, among the modules drawn (not a package from elsewhere)
    MODS[m]['deps'] = [d for d in MODS[m]['deps'] if d in PROD and d != m]
# Which file uses which: (from, to, the names it uses), each a (module, path in the module); a pair once.
_uses = {}
for u in model['uses']:
    pair = (tuple(u['from']), tuple(u['to']))
    _uses[pair] = _uses.get(pair, []) + [n for n in u['names'] if n not in _uses.get(pair, [])]
USES = [(a, b, names) for (a, b), names in _uses.items()]

def load_spec():
    path = os.path.join(PROJECT, 'spec.py')
    if not os.path.exists(path):
        return None
    s = importlib.util.spec_from_file_location('spec', path)
    mod = importlib.util.module_from_spec(s)
    s.loader.exec_module(mod)
    return mod

import defaults         # noqa: E402
SPEC = defaults.complete(load_spec(), model, PROD, MODS, FILES, USES, PROJECT)
BANDS, PURPOSES, FOLDER_BOARDS, FOLDER_PURPOSES, GROUPS, BY_MODULE, LAYER_PHRASE, TITLE = (
    SPEC.BANDS, SPEC.PURPOSES, SPEC.FOLDER_BOARDS, SPEC.FOLDER_PURPOSES, SPEC.GROUPS, SPEC.BY_MODULE, SPEC.LAYER_PHRASE, SPEC.TITLE)
WARNINGS = SPEC.WARNINGS

# ---- names --------------------------------------------------------------------------------------

def _file_titles():
    """Each file's title: its name, else its module's and its name, else the shortest end of its path (from its
    module's name) that's its own: the first of these no other file could take. A file's whole path is its own,
    so it's never another's."""
    full = {k: f"{k[0]}/{k[1]}" for k in FILES}
    taken = set(full.values())
    def candidates(k):
        m, rel = k
        parts = [m] + rel.split('/')
        shorter = [parts[-1], f"{m}/{parts[-1]}"] + ['/'.join(parts[-i:]) for i in range(2, len(parts))]
        return [c for c in shorter if c not in taken] + [full[k]]
    cands = {k: candidates(k) for k in FILES}
    claimed = collections.Counter(c for k in FILES for c in set(cands[k]))
    return {k: next(c for c in cands[k] if claimed[c] == 1) for k in FILES}

_TITLES = _file_titles()

def ftitle(key):
    return _TITLES[key]

# ---- boards -------------------------------------------------------------------------------------
# A module's board holds its files, or, for a module in FOLDER_BOARDS, a card for each of those folders (each
# a board of its own, titled "<module>/<folder>") and the files outside them.

BOARDS = {}             # a board's title: (its module, its folder or None)
for m in PROD:
    BOARDS[m] = (m, None)
    for folder in FOLDER_BOARDS.get(m, []):
        BOARDS[f"{m}/{folder}"] = (m, folder)

def board_of(key):
    m, rel = key
    folder = rel.split('/')[0] if '/' in rel else None
    return f"{m}/{folder}" if folder in FOLDER_BOARDS.get(m, ()) else m

_on_board = collections.defaultdict(list)
for k in sorted(FILES):
    _on_board[board_of(k)].append(k)

def board_files(board):
    return list(_on_board.get(board, []))

def key_in(board, name):
    """A file of a board by its name in the spec: its path inside the board's folder (or module). None, and a
    warning, when the board has no such file."""
    m, folder = BOARDS[board]
    k = (m, f"{folder}/{name}" if folder else name)
    if k not in FILES:
        WARNINGS.append(f"spec.py names {name} on {board}, which has no such file: left out")
        return None
    if board_of(k) != board:
        WARNINGS.append(f"spec.py names {name} on {board}, but it is on {board_of(k)}'s board: left out of that frame")
        return None
    return k

def as_text(s):
    """Text a note shows as it is: every @[ in it written so draw reads it as the two characters, not a mention (a run of
    backslashes before it doubled, then one more)."""
    return re.sub(r'(\\*)@\[', lambda m: m.group(1) * 2 + '\\@[', s)

def mention(title):
    """A mention of the shape with that title, as draw reads one: its spaces folded as a title's are (a label ends at
    a line break), and in it a backslash and a ] each behind a backslash, so a title like [locale] names its shape."""
    return '@[' + ' '.join(title.split()).replace('\\', '\\\\').replace(']', '\\]') + ']'

# ---- what a note says ---------------------------------------------------------------------------

# How a note says what its file declares, in its language's words: its types by visibility, its public functions.
WORDS = {
    'swift': dict(public='public', internal='internal', private='private', function='public func', extension='extends'),
    'typescript': dict(public='exports', internal='internal', private='declares', function='exports function', extension='extends'),
}
WORDS_ELSE = dict(public='public', internal='internal', private='private', function='functions', extension='extends')

def file_text(key):
    f = FILES[key]
    W = WORDS.get(model['language'], WORDS_ELSE)
    parts = []
    if f['doc']:
        parts.append(f['doc'])
    types = [d for d in f['decls'] if d['kind'] == 'type']
    pub = [d['name'] for d in types if d['visibility'] == 'public']
    rest = [d['name'] for d in types if d['visibility'] == 'internal']
    priv = [d['name'] for d in types if d['visibility'] == 'private']
    exts = sorted(set(d['name'] for d in f['decls'] if d['kind'] == 'extension') - set(d['name'] for d in types))
    funcs = [d['name'] for d in f['decls'] if d['kind'] == 'function' and d['visibility'] == 'public']
    def names(xs, cap=10):
        return ', '.join(xs[:cap]) + (f' +{len(xs) - cap}' if len(xs) > cap else '')
    lines = []
    if pub: lines.append(f"{W['public']} " + names(pub))
    if rest: lines.append(f"{W['internal']} " + names(rest))
    if priv and not pub and not rest: lines.append(f"{W['private']} " + names(priv))
    if funcs: lines.append(f"{W['function']} " + names(funcs, 6))
    if exts: lines.append(f"{W['extension']} " + names(exts, 6))
    lines.append(f"{f['lines']} lines")
    parts.append('\n'.join(lines))
    return '\n\n'.join(parts)

def about_text(board, title=lambda b: b):
    """A board's header note: what it is, and the boards it uses, each mentioned by the title its card was given
    (`title`: a board to its card's title, which is the board's name unless another shape had it)."""
    m, folder = BOARDS[board]
    if folder:
        files = board_files(board)
        uses = collections.Counter()
        for a, b, _ in USES:
            if a[0] == m and b[0] == m and a in FILES and b in FILES and board_of(a) == board and board_of(b) != board:
                uses[board_of(b)] += 1
        n = sum(FILES[k]['lines'] for k in files)
        t = f"{as_text(board)}: a folder of {mention(title(m))}\n{as_text(FOLDER_PURPOSES.get(board, ''))}\n\n" + (
            'Uses ' + ' '.join(mention(title(u)) for u in sorted(uses)) if uses else 'Uses nothing else of its module')
        return t + f"\n{len(files)} files, {n:,} lines"
    mod = MODS[board]
    t = f"{as_text(board)}: {as_text(LAYER_PHRASE[board])}\n{as_text(PURPOSES.get(board, ''))}\n\n"
    t += ('Imports ' + ' '.join(mention(title(d)) for d in mod['deps'])) if mod['deps'] else 'Imports no module of its own'
    users = [x for x in PROD if board in MODS[x]['deps']]
    if users:
        t += '\nImported by ' + (' '.join(mention(title(u)) for u in users) if len(users) <= 12 else f'{len(users)} modules')
    files = [k for k in FILES if k[0] == board]
    t += f"\n{len(files)} files, {mod['lines']:,} lines"
    if board in FOLDER_BOARDS:
        t += '\nIts folders are subboards here.'
    return t
