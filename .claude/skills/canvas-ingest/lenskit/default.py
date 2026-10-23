"""The default lens: a codebase as a digest, from the scan alone.

    from lenskit import default
    def digest(scan, repo):
        return default.digest(scan, repo)                       # or with overrides: default.digest(scan, repo, bands=[...])

The root holds the modules as cards in bands, a band a layer, the top layer first (each band's `rank`: rows or columns, as
the skill finds the view shows larger); a module's imports are edges between the cards. A module's board holds its files as
notes in frames (`groups`, else by folder), and a module in `folder_boards` holds a card for each of those folders, whose
board holds its files. Which file uses which is an edge, as heavy as the names it uses; one to a file on another board is a
pill there, and that file is public. What a board is, is said in its card's `text` (the card's description in the app). Every node
says where it came from in `source`: a file note its path, a module's card (and a folder's) its folder.

The overrides are the arguments, each the value a repository's spec.py once gave its name:

    title            what the whole is called                                   (str)
    bands            the root's bands, top to bottom                            [(title, [module])]
    purposes         a module's purpose                                         {module: text}
    folder_purposes  a folder board's purpose                                   {"<module>/<folder>": text}
    folder_boards    the folders of a module that get boards of their own       {module: [folder]}
    groups           a board's frames                                           {board: [(title, [file], [subgroup])]}
    by_module        files whose arrows point at modules, not files             [(module, file)]
    layer_names      how a layer tag reads                                      {tag: name}

Whatever they leave out, or name that the code lacks, is worked out (derive.py) and said in the digest's `warnings`; none stops
the run. A board of over NOTES_MOST file notes draws a folder's files as one note, the deepest folders first (see `collapse`).

A title is given out once in the container that holds the shape, as a folder's files are told apart by the folder they are in: a
file's note is its file name, and so is another's in another frame or on another board, which the digest tells apart by an `id` it
gives each (the title, then the containers: `index.ts  in Web layer > web > src`; lenskit.builder's `finish`). A module's card and a
folder's keep their names, the digest's alone, since a card's description mentions cards (`@[Title]` names a shape by its title
alone); a band, a frame, a file's note give way to them."""
import collections, os

from . import derive
from .builder import Digest, whole
from .text import as_text, declares, file_text, mention

ARGUMENTS = ('title', 'bands', 'purposes', 'folder_purposes', 'folder_boards', 'groups', 'by_module', 'layer_names')

MAX_WEIGHT = 4          # an edge's weight is the names its file uses of the other, up to this
NOTES_MOST = 4000       # file notes a digest may have: one title query lists at most 10,000 titles, and a monorepo has many thousands of files
LISTED_MOST = 300       # files a collapsed folder's note lists


def digest(scan, repo=None, **overrides):
    """The digest of the scan (a lenskit Scan). `repo` (a Repo, or a folder's path) is only where the title comes from when
    the scan has no name for the code."""
    return build(scan, repo, **overrides).finish()


def build(scan, repo=None, **overrides):
    """The same digest before it is finished: the `lenskit.Digest` that `digest` calls `finish()` on. A lens that changes the
    digest (moves a card into a frame of its own) does it here, on the nodes (which name each other by node until `finish()`), and
    finishes it itself, so the `id` that `finish()` gives a node whose title another has says where the node ended up."""
    unknown = sorted(set(overrides) - set(ARGUMENTS))
    if unknown:
        raise TypeError(f"default.digest() has no argument {', '.join(unknown)}: its arguments are {', '.join(ARGUMENTS)}")
    name = getattr(repo, 'name', None) or (os.path.basename(os.path.abspath(repo)) if isinstance(repo, str) else None)
    return _Build(scan, name, overrides).build()


def file_titles(files):
    """Each file's title among `files`, the files one container (a frame, or a board's card) holds: its name, else its
    module's and its name, else the shortest end of its path (from its module's name) that's its own there: the first of
    these no other of the files could take. A file's whole path is its own, so it's never another's. A file in another
    container may have the same name; the digest tells them apart by their containers."""
    full = {k: f"{k[0]}/{k[1]}" for k in files}
    taken = set(full.values())
    def candidates(k):
        m, rel = k
        parts = [m] + rel.split('/')
        shorter = [parts[-1], f"{m}/{parts[-1]}"] + ['/'.join(parts[-i:]) for i in range(2, len(parts))]
        return [c for c in shorter if c not in taken] + [full[k]]
    cands = {k: candidates(k) for k in files}
    claimed = collections.Counter(c for k in files for c in set(cands[k]))
    return {k: next(c for c in cands[k] if claimed[c] == 1) for k in files}


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
        self.d = Digest('')
        self.spec = derive.complete(overrides, scan, repo_name, self.d.warn)
        self.FILES, self.MODS, self.PROD, self.USES = scan.files, scan.modules, scan.production, scan.uses
        # A module's board holds its files, or, for a module in FOLDER_BOARDS, a card for each of those folders (each
        # a board of its own, titled "<module>/<folder>") and the files outside them.
        self.BOARDS = {}             # a board's title: (its module, its folder or None)
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
        self.importers = collections.defaultdict(list)           # a module's importers, in the scan's order
        for x in self.PROD:
            for dep in self.MODS[x]['deps']:
                self.importers[dep].append(x)
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
            self.d.warn(f"groups name {name} on {board}, which has no such file: left out")
            return None
        if self.board_of(k) != board:
            self.d.warn(f"groups name {name} on {board}, but it is on {self.board_of(k)}'s board: left out of that frame")
            return None
        return k

    # ---- what a note says ------------------------------------------------------------------------------------

    def about_text(self, board, title=lambda b: b):
        """What a board is, for its card's description: what it is, and the boards it uses, each mentioned by the title its card was given
        (`title`: a board to its card's title, which is the board's name unless another shape had it)."""
        spec, FILES, MODS, PROD = self.spec, self.FILES, self.MODS, self.PROD
        m, folder = self.BOARDS[board]
        if folder:
            files = self.board_files(board)
            uses = self.leaving.get(board, {})
            n = sum(FILES[k]['lines'] for k in files)
            t = f"{as_text(board)}: a folder of {mention(title(m))}\n{as_text(spec.FOLDER_PURPOSES.get(board, ''))}\n\n" + (
                'Uses ' + ' '.join(mention(title(u)) for u in sorted(uses)) if uses else 'Uses nothing else of its module')
            return t + f"\n{len(files)} files, {n:,} lines"
        mod = MODS[board]
        t = f"{as_text(board)}: {as_text(spec.LAYER_PHRASE[board])}\n{as_text(spec.PURPOSES.get(board, ''))}\n\n"
        t += ('Imports ' + ' '.join(mention(title(d)) for d in mod['deps'])) if mod['deps'] else 'Imports no module of its own'
        users = self.importers.get(board, [])
        if users:
            t += '\nImported by ' + (' '.join(mention(title(u)) for u in users) if len(users) <= 12 else f'{len(users)} modules')
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

    # ---- the digest ------------------------------------------------------------------------------------------

    def build(self):
        d, spec, FILES, MODS, PROD, USES = self.d, self.spec, self.FILES, self.MODS, self.PROD, self.USES
        BOARDS, board_of, board_files = self.BOARDS, self.board_of, self.board_files
        d.title = spec.TITLE
        GROUPS, BY_MODULE = spec.GROUPS, spec.BY_MODULE

        # what the overrides name that isn't there: said, and passed over
        for board in GROUPS:
            if board not in BOARDS:
                d.warn(f"groups name a board the code lacks, passed over: {board}")
        for m, folders in spec.FOLDER_BOARDS.items():
            for folder in folders:
                if not board_files(f"{m}/{folder}"):
                    d.warn(f"folder_boards give {m}/{folder} a board, and it has no files")
        for k in sorted(BY_MODULE):
            if k not in FILES:
                d.warn(f"by_module names {k[0]}/{k[1]}, which the code lacks: passed over")

        # a board with too many file notes draws folders as one note
        folders = collapse(FILES)
        rep = {k: ks[0] for ks in folders.values() for k in ks}         # a collapsed file: the first of its folder's, which stands for them
        notes = len(FILES) - sum(len(ks) - 1 for ks in folders.values())
        if folders:
            d.warn(f"{len(folders)} folders were collapsed, each into one note that lists its files ({len(FILES) - notes + len(folders)} files "
                   f"in {len(folders)} notes): a digest may have at most {NOTES_MOST:,} file notes, and this one has {len(FILES):,} files")
            if notes > NOTES_MOST:
                d.warn(f"{notes:,} file notes are left, since no folder with two files is left to collapse")

        # the titles that are the digest's alone, since a card's description mentions cards and `@[Title]` names a shape by its title
        # alone: a module's card keeps its name, then a folder's card, and a band gives way to either (a frame or a file, below, to
        # any card)
        card_title = {m: d.claim(f"the module {m}", m, alone=True) for m in PROD}
        for board, (m, folder) in BOARDS.items():
            if folder:
                card_title[board] = d.claim(f"the folder {board}", board, alone=True)
        bands = [(d.claim(f"the band {band}", band, f"{band} (layer)"), mods) for band, mods in spec.BANDS]

        def source(path):
            return {'source': whole(path)} if path else {}     # as a title is: half a character in a path reads as U+FFFD

        # the nodes, in the order the digest lists them: the root's bands, each with the cards of its modules (a card's description
        # says what the module is), the folders' cards, then the frames and the notes, which take their titles below
        card = {}
        for rank, (band, mods) in enumerate(bands):
            frame = d.frame(band, rank=rank)
            for m in mods:
                card[m] = d.subboard(card_title[m], frame, self.about_text(m, card_title.get), **source(MODS[m].get('path')))
        for board, (m, folder) in BOARDS.items():
            if folder:
                where = MODS[m].get('path')
                card[board] = d.subboard(card_title[board], card[m], self.about_text(board, card_title.get),
                                         **source(f"{where}/{folder}" if where else None))

        frame_of = {}                                          # a file's frame
        frames_in = collections.defaultdict(list)              # a container's frames, in order: (the frame, what it is, its title, then its other)
        said = []                                              # what is said of a frame once it has its title

        def add_group(group, board, parent):
            title, names, subs = group
            frame = d.frame(title, parent)
            frames_in[id(parent)].append((frame, f"the frame {title} on {board}", title, f"{title} ({card_title[board]})"))
            for name in names:
                k = self.key_in(board, name)
                if k is None:
                    continue
                if k in frame_of:
                    said.append(lambda name=name, board=board, first=frame_of[k]:
                                d.warn(f"groups put {name} on {board} in two frames: it stays in \"{first['title']}\""))
                    continue
                frame_of[k] = frame
            for sub in subs:
                add_group(sub, board, frame)

        for board in BOARDS:
            for group in GROUPS.get(board, []):
                add_group(group, board, card[board])
            files = board_files(board)
            if GROUPS.get(board):
                loose = [k for k in files if k not in frame_of]
                if loose:
                    # the files the groups don't name: in a frame of their own, never dropped
                    frame = d.frame(f"{board}/", card[board])
                    frames_in[id(card[board])].append((frame, f"the frame of {board}'s own files", f"{board}/", f"{board}/ ({card_title[board]})"))
                    for k in loose:
                        frame_of[k] = frame
                    said.append(lambda board=board, loose=loose, frame=frame:
                                d.warn(f"groups for {board} leave out {', '.join(k[1] for k in loose)}: they go in the frame \"{frame['title']}\""))

        members = {ks[0]: ks for ks in folders.values()}
        notes_in = collections.defaultdict(list)               # a container's notes, in the scan's order: (the file, its note, whether it stands for a folder)
        note_of = {}
        for k in sorted(FILES):
            if k in rep and rep[k] != k:
                continue
            if k in members:
                frame = next((frame_of[j] for j in members[k] if j in frame_of), None)
                where = os.path.dirname(FILES[k].get('path') or '')
                parent = frame or card[board_of(k)]
                note = d.note(k[1], parent, as_text(self.folder_text(members[k])), **source(where))
            else:
                parent = frame_of.get(k, card[board_of(k)])
                note = d.note(k[1], parent, as_text(file_text(FILES[k], self.scan.language)), **source(FILES[k].get('path')))
            note_of[k] = note
            notes_in[id(parent)].append((k, note, k in members))

        # the titles of what each card and frame holds, a container at a time: a title is given out once in its container, the notes
        # first (file_titles: a file's name, else as much of its path as tells it apart there; a collapsed folder's note is titled for
        # the folder), then the frames, which take their board's name after theirs when a note has their own
        for container in [n for n in d.nodes if n['kind'] != 'sticky-note']:
            entries = notes_in.get(id(container), [])
            names = file_titles([k for k, _, folder in entries if not folder])
            for k, note, folder in entries:
                if folder:
                    m, path = k[0], k[1].rpartition('/')[0]
                    wanted = f"{m}/{path}/" if path else f"{m}/"
                    note['title'] = d.claim(f"the folder {wanted}", wanted, f"{wanted} (files)", within=container)
                else:
                    note['title'] = d.claim(f"{k[0]}/{k[1]}", names[k], f"{k[0]}/{k[1]}", within=container)
            for frame, what, wanted, other in frames_in.get(id(container), []):
                frame['title'] = d.claim(what, wanted, other, within=container)
        for say in said:
            say()

        # the edges: a module's imports on the root, and which file uses which (a BY_MODULE file's, the modules it uses); the
        # edges of the files of a collapsed folder are the folder note's, their weights added up
        for m in PROD:
            for dep in MODS[m]['deps']:
                d.edge(card[m], card[dep])
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
            d.edge(note_of[a], note_of[b], weight)
        for a in sorted(by_module):
            for m in sorted(by_module[a]):
                d.edge(note_of[a], card[m])
        return d
