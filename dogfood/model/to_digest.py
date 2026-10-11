#!/usr/bin/env python3
"""A codebase as a digest, the JSON the canvas-digest skill lays out, from model.json (a reader's) and the project's
spec.py, if it has one.
    to_digest.py <digest.json>          PROJECT is the project's directory (this one when unset)

The root holds the modules as cards in bands, a band a layer, the top layer first (each band's `rank`: rows or
columns, as the skill finds the view shows larger); a module's
imports are edges between the cards. A module's board holds its files as notes in frames (spec.py's GROUPS, else
by folder), and a module in FOLDER_BOARDS holds a card for each of those folders, whose board holds its files. Which
file uses which is an edge, as heavy as the names it uses; one to a file on another board is a pill there, and that
file is public. A board's header note says what the board is: its card's `text`, and the digest's own for the root.
A spec is overrides: whatever it leaves out, or names that the code no longer has, is worked out and said on
standard error, and never stops the run."""
import collections, json, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common                                                          # noqa: E402
from common import (FILES, MODS, PROD, USES, BANDS, FOLDER_BOARDS, GROUPS, BY_MODULE, TITLE, BOARDS, WARNINGS,  # noqa: E402
                    ftitle, board_of, board_files, key_in, file_text, about_text, as_text)

MAX_WEIGHT = 4          # an edge's weight is the names its file uses of the other, up to this
LONGEST = 80            # a title's most characters, as the digest counts them
HEADED = LONGEST - len('About ')    # a card's: its board's header note is titled "About <card>"


def fold(title):
    """A title as the digest tells titles apart: spaces folded, case aside."""
    return ' '.join(title.split()).lower()


def units(title):
    return len(title.encode('utf-16-le', 'surrogatepass')) // 2      # the digest's count: UTF-16 units


def whole(title):
    """A name as a title can hold it: half a character (a file's name that isn't UTF-8 is read with those) reads as
    U+FFFD, which is what writing it to a script would make of it."""
    return ''.join('\ufffd' if 0xD800 <= ord(ch) <= 0xDFFF else ch for ch in title)


def clip(title, most):
    """A title of at most `most` characters: one over keeps its end, which is what tells it apart, behind an ellipsis."""
    if units(title) <= most:
        return title
    while units(title) > most - 1:
        title = title[1:]
    return '…' + title


class Titles:
    """Every shape's title, given out once. A title another shape has (spaces folded, case aside), or one over the
    longest a title may be, gives way: to the next it is offered, then to a number after the last. Each is said in
    WARNINGS; none stops the run."""

    def __init__(self):
        self.taken = set()

    def claim(self, what, wanted, *others, most=LONGEST):
        offered = [whole(wanted), *(whole(o) for o in others)]
        title = next((t for t in (clip(o, most) for o in offered) if fold(t) and fold(t) not in self.taken), None)
        n = 2
        while title is None:
            numbered = f" ({n})"
            t = clip(offered[-1], most - len(numbered)) + numbered
            title, n = (t if fold(t) not in self.taken else None), n + 1
        if title != wanted:
            why = ("its name isn't whole text" if title == offered[0]
                   else f"its name is over {most} characters" if title == clip(offered[0], most)
                   else "it has no name" if not fold(offered[0])
                   else f"\"{offered[0]}\" is another shape's title too")
            WARNINGS.append(f"{whole(what)} is titled \"{title}\": {why}")
        self.taken.add(fold(title))
        return title


def build():
    nodes, edges, titles = [], [], Titles()

    def add(title, kind, parent=None, text=None, **extra):
        node = {'title': title, 'kind': kind}
        if parent:
            node['in'] = parent
        if text:
            node['text'] = text
        node.update(extra)
        nodes.append(node)

    # what the spec names that isn't there: said, and passed over
    for board in GROUPS:
        if board not in BOARDS:
            WARNINGS.append(f"spec.py's GROUPS name a board the code lacks, passed over: {board}")
    for m, folders in FOLDER_BOARDS.items():
        for folder in folders:
            if not board_files(f"{m}/{folder}"):
                WARNINGS.append(f"spec.py's FOLDER_BOARDS give {m}/{folder} a board, and it has no files")
    for k in sorted(BY_MODULE):
        if k not in FILES:
            WARNINGS.append(f"spec.py's BY_MODULE names {k[0]}/{k[1]}, which the code lacks: passed over")

    # the titles, the ones that matter most first: a module's card keeps its name, then a folder's card, a band, a file
    # (common.ftitle: its name, else as much of its path as tells it apart), and last a frame, which takes its board's
    # name after it when another shape has its own
    card = {m: titles.claim(f"the module {m}", m, most=HEADED) for m in PROD}
    for board, (m, folder) in BOARDS.items():
        if folder:
            card[board] = titles.claim(f"the folder {board}", board, most=HEADED)
    bands = [(titles.claim(f"the band {band}", band, f"{band} (layer)"), mods) for band, mods in BANDS]
    file_title = {k: titles.claim(f"{k[0]}/{k[1]}", ftitle(k), f"{k[0]}/{k[1]}") for k in sorted(FILES)}

    # the root: the bands, a module's card in its band, and each card's board header, which says what the module is
    for rank, (band, mods) in enumerate(bands):
        add(band, 'frame', rank=rank)
        for m in mods:
            add(card[m], 'subboard', band, about_text(m, card.get))
    for board, (m, folder) in BOARDS.items():
        if folder:
            add(card[board], 'subboard', card[m], about_text(board, card.get))

    frame_of = {}

    def add_group(group, board, parent):
        title, names, subs = group
        t = titles.claim(f"the frame {title} on {board}", title, f"{title} ({card[board]})")
        add(t, 'frame', parent)
        for name in names:
            k = key_in(board, name)
            if k is None:
                continue
            if k in frame_of:
                WARNINGS.append(f"spec.py puts {name} on {board} in two frames: it stays in \"{frame_of[k]}\"")
                continue
            frame_of[k] = t
        for sub in subs:
            add_group(sub, board, t)

    for board in BOARDS:
        for group in GROUPS.get(board, []):
            add_group(group, board, card[board])
        files = board_files(board)
        if GROUPS.get(board):
            loose = [k for k in files if k not in frame_of]
            if loose:
                # the files spec.py doesn't name: in a frame of their own, never dropped
                t = titles.claim(f"the frame of {board}'s own files", f"{board}/", f"{board}/ ({card[board]})")
                add(t, 'frame', card[board])
                for k in loose:
                    frame_of[k] = t
                WARNINGS.append(f"spec.py's GROUPS for {board} leave out {', '.join(k[1] for k in loose)}: "
                                f"they go in the frame \"{t}\"")

    for k in sorted(FILES):
        add(file_title[k], 'sticky-note', frame_of.get(k, card[board_of(k)]), as_text(file_text(k)))

    # the edges: a module's imports on the root, and which file uses which (a BY_MODULE file's, the modules it uses)
    for m in PROD:
        for d in MODS[m]['deps']:
            edges.append({'from': card[m], 'to': card[d]})
    by_module = collections.defaultdict(set)
    for a, b, names in USES:
        if a not in FILES or b not in FILES or a == b:
            continue
        if a in BY_MODULE:
            if b[0] != a[0]:
                by_module[a].add(b[0])
            continue
        edges.append({'from': file_title[a], 'to': file_title[b], 'weight': min(MAX_WEIGHT, max(1, len(names)))})
    for a in sorted(by_module):
        for m in sorted(by_module[a]):
            edges.append({'from': file_title[a], 'to': card[m]})

    files, lines = len(FILES), sum(f['lines'] for f in FILES.values())
    text = (f"{as_text(TITLE)}: {len(PROD)} modules in {len(BANDS)} layers, {files} files, {lines:,} lines.\n"
            f"A card is a module: open it for its files. An arrow, or a pill, is an import.")
    return {'title': TITLE, 'text': text, 'nodes': nodes, 'edges': edges}


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    digest = build()
    for w in WARNINGS:
        print(f"to_digest: {w}", file=sys.stderr)
    with open(sys.argv[1], 'w') as f:
        json.dump(digest, f, indent=1)
        f.write('\n')
    kinds = collections.Counter(n['kind'] for n in digest['nodes'])
    print(f"to_digest: {kinds['subboard']} cards, {kinds['frame']} frames, {kinds['sticky-note']} notes, "
          f"{len(digest['edges'])} edges into {sys.argv[1]}")


if __name__ == '__main__':
    main()
