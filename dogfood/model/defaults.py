"""What a project's spec.py doesn't say, worked out from the model. Each of the spec's names is taken whole when
the spec has it, and worked out otherwise:

    BANDS           the root's bands, top to bottom: (title, [module]). By the modules' layer tags when every
                    module has one, else by how deep each module's imports go (a cycle's modules share a level).
    LAYER_NAMES     how a layer tag reads: none.
    PURPOSES        a module's purpose: what its reader found (a README, a package's or module's doc comment).
    FOLDER_BOARDS   {module: [folder]}, the folders of a module that get boards of their own: a module of more
                    than BIG files gives one to each of its top folders, when it has two or more.
    FOLDER_PURPOSES a folder board's purpose: what the reader found for the folder.
    GROUPS          {board: [(title, [file], [subgroup])]}, frames: a board's files by their folders, two deep,
                    each titled by the shortest end of its folder's path that no other frame, module or board takes
                    (the board's own files in one titled "<board>/").
    BY_MODULE       files whose pills stand for modules, not files: none.
    TITLE           what the whole is called, the root's header: the name its reader found (the package's own, a
                    repository's folder), else the project directory's name.

A spec is overrides, never a list the code must match: a module its BANDS leave out goes in the band of its layer
tag, else a band of its own at the bottom; one it names that the code lacks is passed over. Each is said in WARNINGS,
and nothing stops the run. LAYER_PHRASE, the first line of a module's About note, follows from the bands."""
import collections, os

BIG = 50

class Spec:
    pass

def complete(spec, model, prod, mods, files, uses, project):
    s = Spec()
    s.WARNINGS = []
    have = lambda name: spec is not None and hasattr(spec, name)
    s.TITLE = spec.TITLE if have('TITLE') else model.get('name') or os.path.basename(os.path.abspath(project))
    s.LAYER_NAMES = spec.LAYER_NAMES if have('LAYER_NAMES') else {}
    s.FOLDER_BOARDS = spec.FOLDER_BOARDS if have('FOLDER_BOARDS') else folder_boards(prod, files)
    unknown = [m for m in s.FOLDER_BOARDS if m not in prod]
    if unknown:
        s.WARNINGS.append(f"spec.py's FOLDER_BOARDS name modules the code lacks, passed over: {', '.join(unknown)}")
        s.FOLDER_BOARDS = {m: fs for m, fs in s.FOLDER_BOARDS.items() if m in prod}
    # a folder's board is called "<module>/<folder>": where a module has that very name, the folder gets no board of
    # its own (its files stay on its module's board), so the two are never one board
    for m, fs in list(s.FOLDER_BOARDS.items()):
        named = [f for f in fs if f"{m}/{f}" in prod]
        if named:
            s.WARNINGS.append(f"{', '.join(f'{m}/{f}' for f in named)}: a module has that name, so the folder gets no board "
                              f"of its own and its files stay on {m}'s")
            s.FOLDER_BOARDS = {**s.FOLDER_BOARDS, m: [f for f in fs if f not in named]}
    s.BANDS = spec.BANDS if have('BANDS') else bands(prod, mods, s.LAYER_NAMES)
    s.BANDS = settle_bands(s.BANDS, prod, mods, s.LAYER_NAMES, s.WARNINGS)
    s.PURPOSES = spec.PURPOSES if have('PURPOSES') else {m: mods[m].get('doc') or '' for m in prod}
    for folder_key in [k for k in (spec.PURPOSES if have('PURPOSES') else {}) if k not in prod]:
        s.WARNINGS.append(f"spec.py's PURPOSES name a module the code lacks, passed over: {folder_key}")
    s.FOLDER_PURPOSES = spec.FOLDER_PURPOSES if have('FOLDER_PURPOSES') else {
        f"{m}/{folder}": (mods[m].get('folders') or {}).get(folder) or '' for m, fs in s.FOLDER_BOARDS.items() for folder in fs}
    s.GROUPS = spec.GROUPS if have('GROUPS') else groups(prod, files, s.FOLDER_BOARDS)
    s.BY_MODULE = spec.BY_MODULE if have('BY_MODULE') else set()
    band_of = {m: t for t, ms in s.BANDS for m in ms}
    s.LAYER_PHRASE = {m: f"{s.LAYER_NAMES.get(mods[m]['layer'], mods[m]['layer'])} layer" if mods[m].get('layer')
                      else band_of[m][0].lower() + band_of[m][1:] for m in prod}
    return s

def settle_bands(given, prod, mods, names, warnings):
    """The spec's bands with every module the code has: one it lacks is passed over, and one it leaves out goes in
    the band whose modules share its layer tag, else in a band of its own at the bottom ("Other modules")."""
    unknown = [m for _, ms in given for m in ms if m not in prod]
    if unknown:
        warnings.append(f"spec.py's BANDS name modules the code lacks, passed over: {', '.join(unknown)}")
    out, placed = [], set()
    for t, ms in given:
        band = []
        for m in ms:
            if m not in prod:
                continue
            if m in placed:
                warnings.append(f"spec.py's BANDS put {m} in two bands: it stays in the first")
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
        warnings.append(f"spec.py's BANDS leave out {m}: it goes in \"{home[0]}\"")
    return [b for b in out if b[1]]

def folder_boards(prod, files):
    out = {}
    for m in prod:
        rels = [rel for (mm, rel) in files if mm == m]
        if len(rels) <= BIG:
            continue
        count = collections.Counter(rel.split('/')[0] for rel in rels if '/' in rel)
        folders = sorted(count)
        if len(folders) >= 2:
            out[m] = folders
    return out

def levels(prod, mods):
    """Each module's level: 0 when it imports none of the others, else one more than the highest it imports. The
    modules of an import cycle share a level."""
    index, low, stack, on, comp, n = {}, {}, [], set(), {}, [0]
    def strong(v):         # Tarjan's strongly connected components
        index[v] = low[v] = n[0]; n[0] += 1
        stack.append(v); on.add(v)
        for w in mods[v]['deps']:
            if w not in index:
                strong(w); low[v] = min(low[v], low[w])
            elif w in on:
                low[v] = min(low[v], index[w])
        if low[v] == index[v]:
            while True:
                w = stack.pop(); on.discard(w); comp[w] = v
                if w == v: break
    for v in prod:
        if v not in index:
            strong(v)
    level = {}
    def lv(c):
        if c not in level:
            level[c] = 0
            level[c] = 1 + max((lv(comp[d]) for m in prod if comp[m] == c for d in mods[m]['deps'] if comp[d] != c), default=-1)
        return level[c]
    return {m: lv(comp[m]) for m in prod}

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

def groups(prod, files, folder_boards):
    """Frames from folders, for every board with files in folders below it, each titled by the shortest end of
    its folder's path that no other frame, module or board could take."""
    out = full_groups(prod, files, folder_boards)
    reserved = set(prod) | {f"{m}/{f}" for m, fs in folder_boards.items() for f in fs}
    paths = [g[0] for gs in out.values() for top in gs for g in [top] + top[2]]
    def candidates(path):
        parts = path.rstrip('/').split('/')
        if path.endswith('/'):
            return [path]       # a board's own files: "<board>/"
        return ['/'.join(parts[-i:]) for i in range(1, len(parts))] + [path]
    taken = set(paths) | reserved
    cands = {p: [c for c in candidates(p)[:-1] if c not in taken] + [p] for p in paths}
    claimed = collections.Counter(c for p in paths for c in set(cands[p]))
    title = {p: next(c for c in cands[p] if claimed[c] == 1) for p in paths}
    return {b: [(title[t], fs, [(title[s], sfs, ss) for s, sfs, ss in subs]) for t, fs, subs in gs] for b, gs in out.items()}

def full_groups(prod, files, folder_boards):
    out = {}
    for m in prod:
        boards = {None: m}
        boards.update({f: f"{m}/{f}" for f in folder_boards.get(m, [])})
        by_board = collections.defaultdict(list)
        for (mm, rel) in sorted(files):
            if mm != m: continue
            top = rel.split('/')[0] if '/' in rel else None
            folder = top if top in boards and top is not None else None
            inner = rel[len(folder) + 1:] if folder else rel
            by_board[folder].append(inner)
        for folder, rels in by_board.items():
            if not any('/' in r for r in rels):
                continue
            prefix = f"{m}/{folder}" if folder else m
            loose = [r for r in rels if '/' not in r]
            tops = sorted(set(r.split('/')[0] for r in rels if '/' in r))
            gs = [(f"{prefix}/", loose, [])] if loose else []
            for t in tops:
                inside = [r[len(t) + 1:] for r in rels if r.startswith(t + '/')]
                direct = [t + '/' + r for r in inside if '/' not in r]
                subs = sorted(set(r.split('/')[0] for r in inside if '/' in r))
                gs.append((f"{prefix}/{t}", direct,
                           [(f"{prefix}/{t}/{u}", [t + '/' + r for r in inside if r.startswith(u + '/')], []) for u in subs]))
            out[boards[folder]] = gs
    return out
