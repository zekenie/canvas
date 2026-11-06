"""What the default lens works out from the scan when a lens doesn't say. Each of the overrides (the arguments of
`default.digest`) is taken whole when it is given, and worked out otherwise:

    bands            the root's bands, top to bottom: (title, [module]). By the modules' layer tags when every
                     module has one, else by how deep each module's imports go (a cycle's modules share a level).
    layer_names      how a layer tag reads: none.
    purposes         a module's purpose: what its reader found (a README, a package's or module's doc comment).
    folder_boards    {module: [folder]}, the folders of a module that get boards of their own: a module of more
                     than BIG files gives one to each of its top folders, when it has two or more.
    folder_purposes  a folder board's purpose: what the reader found for the folder.
    groups           {board: [(title, [file], [subgroup])]}, frames: a board's files by their folders, two deep,
                     each titled by its folder's name (the board's own files in one titled by the board's folder, or
                     its module): a title is what the code calls the folder, so two boards may each have a `utils`.
                     A group is (title, files, subgroups) or, with a key of its own, (title, files, subgroups, key);
                     those worked out from folders are keyed `dir:<path>`.
    by_module        files whose pills stand for modules, not files: none.
    drawing          what the drawing is called: the name its reader found (the package's own), else the repository's.

These are overrides, never a list the code must match: a module `bands` leaves out goes in the band of its layer
tag, else a band of its own at the bottom; one it names that the code lacks is passed over. Each is said through
`warn`, and nothing stops the run. `layer_phrase`, the first line of a module's description, follows from the bands."""
import collections

BIG = 50


class Spec:
    pass


def complete(given, scan, repo_name, warn):
    """The settled names (attributes of the result, in capitals) from the overrides `given` ({name: value}); what the
    overrides leave out is worked out from the scan, and what they name that the code lacks is passed over, said through `warn`."""
    prod, mods, files = scan.production, scan.modules, scan.files
    s = Spec()
    have = lambda name: name in given
    s.DRAWING = given['drawing'] if have('drawing') else None
    s.LAYER_NAMES = given['layer_names'] if have('layer_names') else {}
    s.FOLDER_BOARDS = given['folder_boards'] if have('folder_boards') else folder_boards(prod, files)
    unknown = [m for m in s.FOLDER_BOARDS if m not in prod]
    if unknown:
        warn(f"folder_boards name modules the code lacks, passed over: {', '.join(unknown)}")
        s.FOLDER_BOARDS = {m: fs for m, fs in s.FOLDER_BOARDS.items() if m in prod}
    # a folder's board is called "<module>/<folder>": where a module has that very name, the folder gets no board of
    # its own (its files stay on its module's board), so the two are never one board
    for m, fs in list(s.FOLDER_BOARDS.items()):
        named = [f for f in fs if f"{m}/{f}" in prod]
        if named:
            warn(f"{', '.join(f'{m}/{f}' for f in named)}: a module has that name, so the folder gets no board "
                 f"of its own and its files stay on {m}'s")
            s.FOLDER_BOARDS = {**s.FOLDER_BOARDS, m: [f for f in fs if f not in named]}
    s.BANDS = given['bands'] if have('bands') else bands(prod, mods, s.LAYER_NAMES)
    s.BANDS = settle_bands(s.BANDS, prod, mods, s.LAYER_NAMES, warn)
    s.PURPOSES = given['purposes'] if have('purposes') else {m: mods[m].get('doc') or '' for m in prod}
    for folder_key in [k for k in (given['purposes'] if have('purposes') else {}) if k not in prod]:
        warn(f"purposes name a module the code lacks, passed over: {folder_key}")
    s.FOLDER_PURPOSES = given['folder_purposes'] if have('folder_purposes') else {
        f"{m}/{folder}": (mods[m].get('folders') or {}).get(folder) or '' for m, fs in s.FOLDER_BOARDS.items() for folder in fs}
    s.GROUPS = given['groups'] if have('groups') else groups(prod, mods, files, s.FOLDER_BOARDS)
    s.BY_MODULE = {tuple(k) for k in given['by_module']} if have('by_module') else set()
    band_of = {m: t for t, ms in s.BANDS for m in ms}
    s.LAYER_PHRASE = {m: f"{s.LAYER_NAMES.get(mods[m]['layer'], mods[m]['layer'])} layer" if mods[m].get('layer')
                      else band_of[m][0].lower() + band_of[m][1:] for m in prod}
    return s


def settle_bands(given, prod, mods, names, warn):
    """The given bands with every module the code has: one it lacks is passed over, and one it leaves out goes in
    the band whose modules share its layer tag, else in a band of its own at the bottom ("Other modules")."""
    unknown = [m for _, ms in given for m in ms if m not in prod]
    if unknown:
        warn(f"bands name modules the code lacks, passed over: {', '.join(unknown)}")
    out, placed = [], set()
    for t, ms in given:
        band = []
        for m in ms:
            if m not in prod:
                continue
            if m in placed:
                warn(f"bands put {m} in two bands: it stays in the first")
                continue
            placed.add(m)
            band.append(m)
        out.append((t, band))
    for m in prod:
        if m in placed:
            continue
        tag = mods[m].get('layer')
        home = next((b for b in out if tag and any(mods[x].get('layer') == tag for x in b[1])), None)
        if home is None:
            home = next((b for b in out if b[0] == 'Other modules'), None)
            if home is None:
                home = ('Other modules', [])
                out.append(home)
        home[1].append(m)
        warn(f"bands leave out {m}: it goes in \"{home[0]}\"")
    return [b for b in out if b[1]]


def folder_boards(prod, files):
    out = {}
    of_module = collections.defaultdict(list)
    for (mm, rel) in files:
        of_module[mm].append(rel)
    for m in prod:
        rels = of_module.get(m, [])
        if len(rels) <= BIG:
            continue
        count = collections.Counter(rel.split('/')[0] for rel in rels if '/' in rel)
        folders = sorted(count)
        if len(folders) >= 2:
            out[m] = folders
    return out


def levels(prod, mods):
    """Each module's level: 0 when it imports none of the others, else one more than the highest it imports. The
    modules of an import cycle share a level. (Tarjan's strongly connected components, with a stack of its own: a chain of
    thousands of modules is no recursion. A component is complete only after every component it imports is, so its level is
    settled the moment it is.)"""
    index, low, stack, on, comp, level = {}, {}, [], set(), {}, {}
    count = 0
    for root in prod:
        if root in index:
            continue
        index[root] = low[root] = count
        count += 1
        stack.append(root)
        on.add(root)
        work = [(root, iter(mods[root]['deps']))]
        while work:
            v, deps = work[-1]
            for w in deps:
                if w not in index:
                    index[w] = low[w] = count
                    count += 1
                    stack.append(w)
                    on.add(w)
                    work.append((w, iter(mods[w]['deps'])))
                    break
                if w in on:
                    low[v] = min(low[v], index[w])
            else:
                work.pop()
                if work:
                    parent = work[-1][0]
                    low[parent] = min(low[parent], low[v])
                if low[v] == index[v]:
                    members = []
                    while True:
                        w = stack.pop()
                        on.discard(w)
                        comp[w] = v
                        members.append(w)
                        if w == v:
                            break
                    level[v] = 1 + max((level[comp[d]] for m in members for d in mods[m]['deps'] if comp[d] != v), default=-1)
    return {m: level[comp[m]] for m in prod}


def bands(prod, mods, names):
    lv = levels(prod, mods)
    if all(mods[m].get('layer') for m in prod):
        tags = collections.defaultdict(list)
        for m in prod:
            tags[mods[m]['layer']].append(m)
        order = sorted(tags, key=lambda t: (-max(lv[m] for m in tags[t]), t))
        return [(f"{names.get(t, t)[0].upper()}{names.get(t, t)[1:]} layer", tags[t]) for t in order]
    top = max(lv.values(), default=0)
    return [(f"Level {top - i + 1}" if top else "Modules", [m for m in prod if lv[m] == top - i]) for i in range(top + 1)]


def base(mod, name):
    """A module's folder as a path in the repository ('' for the root), else its name where the scan has no path."""
    path = mod.get('path')
    if path is None:
        return name
    path = path.strip('/')
    path = path[2:] if path.startswith('./') else path
    return '' if path == '.' else path


def dir_key(*parts):
    """The key of a folder: `dir:` and its path in the repository."""
    return 'dir:' + ('/'.join(p.strip('/') for p in parts if p.strip('/')) or '.')


def groups(prod, mods, files, folder_boards):
    """Frames from folders, for every board with files in folders below it: a frame for each top folder (its subfolders
    in it), titled by its folder's name and keyed by its path, and the board's own files in one titled by the board's folder
    (the module's name for the module's own)."""
    out = {}
    for board, (m, folder, gs) in full_groups(prod, files, folder_boards).items():
        root = base(mods[m], m)
        prefix = f"{root}/{folder}" if folder else root
        result = []
        for t, fs, subs in gs:
            if t is None:
                result.append((prefix.rpartition('/')[2] or m, fs, [], dir_key(prefix)))
            else:
                result.append((t, fs, [(u, sfs, ss, dir_key(prefix, t, u)) for u, sfs, ss in subs], dir_key(prefix, t)))
        out[board] = result
    return out


def full_groups(prod, files, folder_boards):
    """{board: (module, folder or None, [(top folder or None for the board's own files, [files], [(subfolder, [files], [])])])}: the folders a board's
    files are in, two deep, files by their path in the board's folder."""
    out = {}
    of_module = collections.defaultdict(list)
    for (mm, rel) in sorted(files):
        of_module[mm].append(rel)
    for m in prod:
        boards = {None: m}
        boards.update({f: f"{m}/{f}" for f in folder_boards.get(m, [])})
        by_board = collections.defaultdict(list)
        for rel in of_module.get(m, []):
            top = rel.split('/')[0] if '/' in rel else None
            folder = top if top in boards and top is not None else None
            inner = rel[len(folder) + 1:] if folder else rel
            by_board[folder].append(inner)
        for folder, rels in by_board.items():
            if not any('/' in r for r in rels):
                continue
            loose = [r for r in rels if '/' not in r]
            tops = sorted(set(r.split('/')[0] for r in rels if '/' in r))
            gs = [(None, loose, [])] if loose else []
            for t in tops:
                inside = [r[len(t) + 1:] for r in rels if r.startswith(t + '/')]
                direct = [t + '/' + r for r in inside if '/' not in r]
                subs = sorted(set(r.split('/')[0] for r in inside if '/' in r))
                gs.append((t, direct, [(u, [t + '/' + r for r in inside if r.startswith(u + '/')], []) for u in subs]))
            out[boards[folder]] = (m, folder, gs)
    return out
