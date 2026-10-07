#!/usr/bin/env python3
"""The model every layout reads, each note's text, and the runner.

A project is a directory (PROJECT, else this one) holding model.json, which a reader writes (README.md has its
format), and, where the code doesn't say enough, spec.py: what isn't there is worked out (defaults.py). The
runner dry-runs every script first, and a refusal, or a warning outside EXPECTED, stops it before the real run."""
import importlib.util, json, os, subprocess, sys, collections

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
PROJECT = os.path.abspath(os.path.expanduser(os.environ.get('PROJECT', HERE)))
CLI = os.environ.get('CANVAS_CLI', '/Users/zekenie/code/native-canvas/build/canvas')
BOARD = os.environ.get('CANVAS_BOARD', '2')
RUNS = os.path.join(PROJECT, 'runs')
os.makedirs(RUNS, exist_ok=True)

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
SPEC = defaults.complete(load_spec(), model, PROD, MODS, FILES, USES)
BANDS, PURPOSES, FOLDER_BOARDS, FOLDER_PURPOSES, GROUPS, BY_MODULE, LAYER_PHRASE = (
    SPEC.BANDS, SPEC.PURPOSES, SPEC.FOLDER_BOARDS, SPEC.FOLDER_PURPOSES, SPEC.GROUPS, SPEC.BY_MODULE, SPEC.LAYER_PHRASE)

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

SOURCE_EXTS = ('.swift', '.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs', '.py', '.rb')

def _strip(title):
    return next((title[:-len(x)] for x in SOURCE_EXTS if title.endswith(x)), title)

_stripped = collections.Counter(_strip(t) for t in _TITLES.values())

def bare(title):
    """A file's title without its extension, unless another file's would read the same (`foo.ts` beside `foo.js`)."""
    b = _strip(title)
    return b if b == title or _stripped[b] == 1 else title

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

def folder_boards(m):
    """The boards of a module's folders, in FOLDER_BOARDS' order."""
    return [f"{m}/{folder}" for folder in FOLDER_BOARDS.get(m, [])]

def boards_for(mods):
    """The boards of these modules' files: a module's own, or its folders'."""
    out = []
    for m in mods:
        out += folder_boards(m) if m in FOLDER_BOARDS else [m]
    return out

def key_in(board, name):
    """A file of a board by its name in the spec: its path inside the board's folder (or module)."""
    m, folder = BOARDS[board]
    k = (m, f"{folder}/{name}" if folder else name)
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

def edges_between(drawn):
    """File uses among drawn modules: same-board targets and other-board targets, per file."""
    same = collections.defaultdict(list)
    other = collections.defaultdict(list)
    for a, b, _ in USES:
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
    """Whether a file's note is public: it declares what another module may use, or a file on another
    board uses it (a pill can stand only for a public shape)."""
    if FILES[key]['api']:
        return True
    return any(key in targets for targets in other_all.values())

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
    return plain('\n\n'.join(parts))

def about_title(board):
    return 'About ' + board

def about_text(board):
    m, folder = BOARDS[board]
    if folder:
        files = board_files(board)
        uses = collections.Counter()
        for a, b, _ in USES:
            if a[0] == m and b[0] == m and a in FILES and b in FILES and board_of(a) == board and board_of(b) != board:
                uses[board_of(b)] += 1
        n = sum(FILES[k]['lines'] for k in files)
        t = f"{board}: a folder of @[{m}]\n{FOLDER_PURPOSES.get(board, '')}\n\n" + (
            'Uses ' + ' '.join(f'@[{u}]' for u in sorted(uses)) if uses else 'Uses nothing else of its module')
        return t + f"\n{len(files)} files, {n:,} lines"
    mod = MODS[board]
    t = f"{board}: {LAYER_PHRASE[board]}\n{PURPOSES.get(board, '')}\n\n"
    t += ('Imports ' + ' '.join(f'@[{d}]' for d in mod['deps'])) if mod['deps'] else 'Imports no module of its own'
    users = [x for x in PROD if board in MODS[x]['deps']]
    if users:
        t += '\nImported by ' + (' '.join(f'@[{u}]' for u in users) if len(users) <= 12 else f'{len(users)} modules')
    files = [k for k in FILES if k[0] == board]
    t += f"\n{len(files)} files, {mod['lines']:,} lines"
    if board in FOLDER_BOARDS:
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
