"""The default lens: a codebase as a graph document, from the scan alone.

    from lenskit import default
    def digest(scan, repo):
        return default.digest(scan, repo)                       # or with overrides: default.digest(scan, repo, bands=[...])

The root holds the modules as cards in bands, a band a layer, the top layer first (each band's `rank`: rows or columns, as
the skill finds the view shows larger); a module's imports are edges between the cards. A module's board holds its files as
notes in frames (`groups`, else by folder), and a module in `folder_boards` holds a card for each of those folders, whose
board holds its files. Which file uses which is an edge, as heavy as the names it uses (`layout.weight`); one to a file on
another board is a pill there. What a board is, is said in its card's `description` (shown in its panel).

Every node is keyed by the code, the same from commit to commit, and titled by what the code calls it:

    module:<name>            a module's card              module:<module>/<folder>   a folder's card (`folder_boards`)
    dir:<path>               a folder's frame             file:<path>                a file's note
    files:<path>             a folder drawn as one note   band:<title>               a band of the root

Two `index.ts` in two folders are both titled `index.ts`. The overrides are the arguments:

    drawing          what the drawing is called                                (str; else the runner's)
    bands            the root's bands, top to bottom                            [(title, [module])]
    purposes         a module's purpose                                         {module: text}
    folder_purposes  a folder board's purpose                                   {"<module>/<folder>": text}
    folder_boards    the folders of a module that get boards of their own       {module: [folder]}
    groups           a board's frames                                           {board: [(title, [file], [subgroup])]}
    by_module        files whose arrows point at modules, not files             [(module, file)]
    layer_names      how a layer tag reads                                      {tag: name}

Whatever they leave out, or name that the code lacks, is worked out (derive.py) and said in the document's `warnings`; none stops
the run. A board of over NOTES_MOST file notes draws a folder's files as one note, the deepest folders first (see `collapse`).
`build` gives the Graph before it is finished, for a lens that changes the picture (types its files, moves a card)."""
import collections, os

from . import derive
from .builder import Graph
from .text import as_text, declares, file_text, mention, whole

SUBBOARD, FRAME, NOTE = 'subboard', 'frame', 'sticky-note'
ARGUMENTS = ('drawing', 'bands', 'purposes', 'folder_purposes', 'folder_boards', 'groups', 'by_module', 'layer_names')

MAX_WEIGHT = 4          # an edge's weight is the names its file uses of the other, up to this
NOTES_MOST = 4000       # file notes a document may have: one query lists at most 10,000 titles, and a monorepo has many thousands of files
LISTED_MOST = 300       # files a collapsed folder's note lists




def digest(scan, repo=None, **overrides):
    """The document of the scan (a lenskit Scan). `repo` (a Repo, or a folder's path) is where the drawing's name comes from
    when the scan has no name for the code."""
    return build(scan, repo, **overrides).finish()


def build(scan, repo=None, **overrides):
    """The same document before it is finished: the `lenskit.Graph` that `digest` calls `finish()` on. A lens that changes the
    picture (types its files, moves a card into a frame of its own) does it here, on the nodes, and finishes it itself."""
    unknown = sorted(set(overrides) - set(ARGUMENTS))
    if unknown:
        raise TypeError(f"default.digest() has no argument {', '.join(unknown)}: its arguments are {', '.join(ARGUMENTS)}")
    name = getattr(repo, 'name', None) or (os.path.basename(os.path.abspath(repo)) if isinstance(repo, str) else None)
    return _Build(scan, name, overrides).build()


def collapse(files, most=NOTES_MOST):
    """Which files are drawn as one note of their folder, when there are more than `most`: folders (a module's, and the
    folders in it, a folder's own files, not its subfolders') of two files or more are collapsed one at a time, the deepest
    first, then the one with the most files, then by path, until at most `most` notes are left. Returns {folder: [file]},
    each folder (module, path in the module; "" the module's own) with its files in order; nothing when `files` fit."""
    if len(files) <= most:
        return {}
    folders = collections.defaultdict(list)
    for k in sorted(files):
        folders[(k[0], k[1].rpartition('/')[0])].append(k)
    depth = lambda f: f[1].count('/') + 1 if f[1] else 0
    order = sorted((f for f, ks in folders.items() if len(ks) >= 2), key=lambda f: (-depth(f), -len(folders[f]), f))
    notes, out = len(files), {}
    for f in order:
        if notes <= most:
            break
        out[f] = folders[f]
        notes -= len(folders[f]) - 1
    return out


class _Build:
    """One run of the default lens: the scan, the settled overrides, and the structure of the boards."""

    def __init__(self, scan, repo_name, overrides):
        self.scan = scan
        self.g = Graph()
        self.spec = derive.complete(overrides, scan, repo_name, self.g.warn)
        self.g.drawing = self.spec.DRAWING
        self.FILES, self.MODS, self.PROD, self.USES = scan.files, scan.modules, scan.production, scan.uses
        # A module's board holds its files, or, for a module in FOLDER_BOARDS, a card for each of those folders (each
        # a board of its own, named "<module>/<folder>") and the files outside them.
        self.BOARDS = {}             # a board's name: (its module, its folder or None)
        for m in self.PROD:
            self.BOARDS[m] = (m, None)
            for folder in self.spec.FOLDER_BOARDS.get(m, []):
                self.BOARDS[f"{m}/{folder}"] = (m, folder)
        self.on_board = collections.defaultdict(list)
        for k in sorted(self.FILES):
            self.on_board[self.board_of(k)].append(k)
        # indexed once, so no board looks at every file, or every module, to find its own
        self.module_files = collections.defaultdict(int)         # a module's number of files
        for k in self.FILES:
            self.module_files[k[0]] += 1
        self.leaving = collections.defaultdict(collections.Counter)    # a folder board: the boards of its module its files use
        for a, b, _ in self.USES:
            if a[0] == b[0] and a in self.FILES and b in self.FILES:
                here, there = self.board_of(a), self.board_of(b)
                if here != there and self.BOARDS.get(here, (None,))[0] == a[0]:
                    self.leaving[here][there] += 1

    # ---- boards ----------------------------------------------------------------------------------------------

    def board_of(self, key):
        m, rel = key
        folder = rel.split('/')[0] if '/' in rel else None
        return f"{m}/{folder}" if folder in self.spec.FOLDER_BOARDS.get(m, ()) else m

    def board_files(self, board):
        return list(self.on_board.get(board, []))

    def key_in(self, board, name):
        """A file of a board by its name in the groups: its path inside the board's folder (or module). None, and a
        warning, when the board has no such file."""
        m, folder = self.BOARDS[board]
        k = (m, f"{folder}/{name}" if folder else name)
        if k not in self.FILES:
            self.g.warn(f"groups name {name} on {board}, which has no such file: left out")
            return None
        if self.board_of(k) != board:
            self.g.warn(f"groups name {name} on {board}, but it is on {self.board_of(k)}'s board: left out of that frame")
            return None
        return k

    def free(self, key):
        """The key, else (a key two things came to) the key with a number after it."""
        if key not in self.g.by_key:
            return key
        n = 2
        while f"{key}#{n}" in self.g.by_key:
            n += 1
        return f"{key}#{n}"

    # ---- what a note says ------------------------------------------------------------------------------------

    def about_text(self, board, key):
        """What a board is, for its card's description: what it is and how big, and for a folder's board the boards it uses,
        each mentioned by its card's key (`key`: a board's name to its card's key). A module's imports aren't mentioned: they are
        the arrows between the cards, and a mention of each would crowd the card's mentions, which a hover shows (⌃⌥), with what
        its arrows already show."""
        spec, FILES, MODS = self.spec, self.FILES, self.MODS
        m, folder = self.BOARDS[board]
        if folder:
            files = self.board_files(board)
            uses = self.leaving.get(board, {})
            n = sum(FILES[k]['lines'] for k in files)
            t = f"{as_text(board)}: a folder of {mention(key[m])}\n{as_text(spec.FOLDER_PURPOSES.get(board, ''))}\n\n" + (
                'Uses ' + ' '.join(mention(key[u]) for u in sorted(uses)) if uses else 'Uses nothing else of its module')
            return t + f"\n{len(files)} files, {n:,} lines"
        mod = MODS[board]
        purpose = spec.PURPOSES.get(board, '')
        t = f"{as_text(board)}: {as_text(spec.LAYER_PHRASE[board])}\n" + (f"{as_text(purpose)}\n" if purpose else '')
        t += f"\n{self.module_files[board]} files, {mod['lines']:,} lines"
        if board in spec.FOLDER_BOARDS:
            t += '\nIts folders are subboards here.'
        return t

    def folder_text(self, keys):
        """The note of a collapsed folder: how many files and lines it holds, and each file with what it declares."""
        files = [self.FILES[k] for k in keys]
        lines = [whole(f"{f['rel'].rpartition('/')[2]}: {declares(f)}" if declares(f) else f['rel'].rpartition('/')[2]) for f in files[:LISTED_MOST]]
        if len(files) > LISTED_MOST:
            lines.append(f"+{len(files) - LISTED_MOST} more files")
        return f"{len(files)} files, {sum(f['lines'] for f in files):,} lines\n\n" + '\n'.join(lines)

    # ---- the document ----------------------------------------------------------------------------------------

    def build(self):
        g, spec, FILES, MODS, PROD, USES = self.g, self.spec, self.FILES, self.MODS, self.PROD, self.USES
        BOARDS, board_of, board_files = self.BOARDS, self.board_of, self.board_files
        GROUPS, BY_MODULE = spec.GROUPS, spec.BY_MODULE

        # what the overrides name that isn't there: said, and passed over
        for board in GROUPS:
            if board not in BOARDS:
                g.warn(f"groups name a board the code lacks, passed over: {board}")
        for m, folders in spec.FOLDER_BOARDS.items():
            for folder in folders:
                if not board_files(f"{m}/{folder}"):
                    g.warn(f"folder_boards give {m}/{folder} a board, and it has no files")
        for k in sorted(BY_MODULE):
            if k not in FILES:
                g.warn(f"by_module names {k[0]}/{k[1]}, which the code lacks: passed over")

        # a board with too many file notes draws folders as one note
        folders = collapse(FILES)
        rep = {k: ks[0] for ks in folders.values() for k in ks}         # a collapsed file: the first of its folder's, which stands for them
        notes = len(FILES) - sum(len(ks) - 1 for ks in folders.values())
        if folders:
            g.warn(f"{len(folders)} folders were collapsed, each into one note that lists its files ({len(FILES) - notes + len(folders)} files "
                   f"in {len(folders)} notes): a document may have at most {NOTES_MOST:,} file notes, and this one has {len(FILES):,} files")
            if notes > NOTES_MOST:
                g.warn(f"{notes:,} file notes are left, since no folder with two files is left to collapse")

        # the nodes, in the order the document lists them: the root's bands, each with the cards of its modules (a card's description
        # says what the module is), the folders' cards, then the frames and the notes
        card = {}                                              # a board's name: its card's node
        key = {board: f"module:{whole(board)}" for board in BOARDS}      # a board's name: its card's key (a module's name is its own; a folder board's is "<module>/<folder>")
        for rank, (band, mods) in enumerate(spec.BANDS):
            frame = g.node(self.free(f"band:{whole(band)}"), FRAME, {'title': whole(band)}, layout={'rank': rank})
            for m in mods:
                card[m] = g.node(key[m], SUBBOARD, {'title': whole(m), 'description': self.about_text(m, key)}, in_=frame)
        for board, (m, folder) in BOARDS.items():
            if folder:
                card[board] = g.node(key[board], SUBBOARD, {'title': whole(folder), 'description': self.about_text(board, key)}, in_=card[m])

        frame_of = {}                                          # a file's frame
        said = []                                              # what is said of a frame once all are made

        def add_group(group, board, parent, trail):
            title, names, subs = group[:3]
            where = f"{trail}/{title}"
            frame = g.node(self.free(whole(group[3]) if len(group) > 3 else f"group:{whole(where)}"), FRAME, {'title': whole(title)}, in_=parent)
            for name in names:
                k = self.key_in(board, name)
                if k is None:
                    continue
                if k in frame_of:
                    said.append(lambda name=name, board=board, first=frame_of[k]:
                                g.warn(f"groups put {name} on {board} in two frames: it stays in \"{first['props']['title']}\""))
                    continue
                frame_of[k] = frame
            for sub in subs:
                add_group(sub, board, frame, where)

        for board in BOARDS:
            for group in GROUPS.get(board, []):
                add_group(group, board, card[board], board)
            files = board_files(board)
            if GROUPS.get(board):
                loose = [k for k in files if k not in frame_of]
                if loose:
                    # the files the groups don't name: in a frame of their own, never dropped
                    m, folder = BOARDS[board]
                    frame = g.node(self.free(derive.dir_key(derive.base(MODS[m], m), folder or '')), FRAME, {'title': whole(folder or m)}, in_=card[board])
                    for k in loose:
                        frame_of[k] = frame
                    said.append(lambda board=board, loose=loose, frame=frame:
                                g.warn(f"groups for {board} leave out {', '.join(k[1] for k in loose)}: they go in the frame \"{frame['props']['title']}\""))

        members = {ks[0]: ks for ks in folders.values()}
        note_of = {}
        for k in sorted(FILES):
            if k in rep and rep[k] != k:
                continue
            f = FILES[k]
            if k in members:
                frame = next((frame_of[j] for j in members[k] if j in frame_of), None)
                m, path = k[0], k[1].rpartition('/')[0]
                where = derive.dir_key(derive.base(MODS[m], m), path)[len('dir:'):]
                props = {'title': whole(f"{path.rpartition('/')[2] or m}/"), 'text': as_text(self.folder_text(members[k]))}
                note_of[k] = g.node(self.free(f"files:{whole(where)}"), NOTE, props, in_=frame or card[board_of(k)])
            else:
                props = {'title': whole(k[1].rpartition('/')[2])}
                text = as_text(file_text(f, self.scan.language))
                if text:
                    props['text'] = text
                note_of[k] = g.node(self.free(f"file:{whole(f.get('path') or f'{k[0]}/{k[1]}')}"), NOTE, props, in_=frame_of.get(k) or card[board_of(k)])
        for say in said:
            say()

        # the edges: a module's imports on the root, and which file uses which (a BY_MODULE file's, the modules it uses); the
        # edges of the files of a collapsed folder are the folder note's, their weights added up
        for m in PROD:
            for dep in MODS[m]['deps']:
                g.edge(card[m], card[dep])
        by_module = collections.defaultdict(set)
        weights = {}
        for a, b, names in USES:
            if a not in FILES or b not in FILES or a == b:
                continue
            if a in BY_MODULE:
                if b[0] != a[0]:
                    by_module[rep.get(a, a)].add(b[0])
                continue
            pair = (rep.get(a, a), rep.get(b, b))
            if pair[0] == pair[1]:
                continue
            weights[pair] = min(MAX_WEIGHT, weights.get(pair, 0) + min(MAX_WEIGHT, max(1, len(names))))
        for (a, b), weight in weights.items():
            g.edge(note_of[a], note_of[b], layout={'weight': weight})
        for a in sorted(by_module):
            for m in sorted(by_module[a]):
                g.edge(note_of[a], card[m])
        return g
