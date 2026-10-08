"""Which uses between two files on the same board go through references (pills), and which stay arrows.

    references(board) -> {(from_key, to_key), ...}
        The same-board uses drawn as pills. Every other same-board use is an arrow. A pair used both
        ways is one <-> arrow, or a pill on each side: both of its directions are in the set, or neither.

    references_of(nodes, uses, weight, title=str) -> {(a, b), ...}
        The same rules over any graph: `uses` holds (a, b) when a uses b, weight(a, b) says how much,
        and title(x) breaks ties. references(board) calls it with the board's files, their uses and the
        number of symbols each use names.

The rules read the graph only, never positions:

1. Hubs. h is the graph's h-index: the largest h such that h of its nodes are each used by at least h
   (a pair used both ways counts for both ends). There are hubs only when h >= 3. Three files each used
   by the same three others form K3,3, the smallest pattern of uses that can't be drawn without a
   crossing; below that, every use can be drawn. A node used by more than h nodes is a candidate.
   Candidates become hubs most-used first (ties: more users that it doesn't use back, then the title).
   A candidate is skipped when making it a hub would leave a node tied to it both ways with no arrow
   left: that node hangs on the board by it alone (a plugin and a piece it registers), so the
   candidate keeps all its arrows. Every use of a hub is a pill. A pair with a hub in it is a pill on
   each side. A hub's own one-way uses of other nodes stay arrows.

2. Relays. Of the arrows left, A -> C becomes a pill when a third node B relays it: A -> B and B -> C
   are arrows, B uses C at least as much as A does, and A uses B at least as much as it uses C, unless
   A and B are tied both ways. Two nodes that use each other act as one, so when both use C the arrow
   comes from the one that uses C more. Arrows are checked weakest first, each against the arrows still
   left. A relay that has been counted on is never removed later, so no node loses its last arrow
   this way. A pair goes only when both of its directions are relayed.
"""
import collections, os, sys

MODEL = os.environ.get('MODEL_DIR', os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, MODEL)
import common                                              # noqa: E402  (loads the project's model.json)
from common import PROD, ftitle, board_files, board_of    # noqa: E402

# ---- the rules, over any graph -----------------------------------------------------------------------

def h_index(counts):
    h = 0
    for i, c in enumerate(sorted(counts, reverse=True)):
        if c >= i + 1:
            h = i + 1
    return h

class Graph:
    def __init__(self, nodes, uses, weight, title=str):
        self.key = lambda x: (title(x), repr(x))
        self.nodes = sorted(set(nodes), key=self.key)
        ns = set(self.nodes)
        self.uses = set((a, b) for a, b in uses if a in ns and b in ns and a != b)
        self.weight, self.title = weight, title
        self.users = collections.defaultdict(set)
        for a, b in self.uses:
            self.users[b].add(a)

    def units(self, E):
        """Uses as drawn: (a, b, False) one way, or (a, b, True) for a pair used both ways, a first by key."""
        out = [(a, b, (b, a) in E) for a, b in E if (b, a) not in E or self.key(a) < self.key(b)]
        return sorted(out, key=lambda u: (self.key(u[0]), self.key(u[1])))

    def strength(self, a, b, both):
        return self.weight(a, b) + (self.weight(b, a) if both else 0)

def arrows_without(E, hubs):
    """The uses still arrows once `hubs` are hubs: none into a hub, and no pair with a hub in it."""
    return set((a, b) for a, b in E if b not in hubs and not (a in hubs and (b, a) in E))

def choose_hubs(g):
    """(hubs in the order chosen, h, candidates that keep their arrows because a two-way partner hangs on them)."""
    E, users = g.uses, g.users
    h = h_index([len(users[x]) for x in g.nodes])
    if h < 3:
        return [], h, []
    one_way = {x: sum(1 for a in users[x] if (x, a) not in E) for x in g.nodes}
    candidates = sorted((x for x in g.nodes if len(users[x]) > h),
                        key=lambda x: (-len(users[x]), -one_way[x], g.key(x)))
    hubs, kept = [], []
    for c in candidates:
        left = arrows_without(E, set(hubs) | {c})
        tied = set(x for e in left for x in e)
        partners = [p for p in g.nodes if (c, p) in E and (p, c) in E and p not in hubs]
        if any(p not in tied for p in partners):
            kept.append(c)
        else:
            hubs.append(c)
    return hubs, h, kept

def relayed(g, A, a, c):
    """Whether a third node relays a -> c among the arrows A (which no longer hold a -> c)."""
    s = g.weight(a, c)
    for x, b in A:
        if x == a and b != c and (b, c) in A and g.weight(b, c) >= s and ((b, a) in A or g.weight(a, b) >= s):
            return True
    return False

def relay_reduce(g, A):
    A = set(A)
    for a, c, both in sorted(g.units(A), key=lambda u: (g.strength(*u), g.key(u[0]), g.key(u[1]))):
        unit = {(a, c), (c, a)} if both else {(a, c)}
        rest = A - unit
        if relayed(g, rest, a, c) and (not both or relayed(g, rest, c, a)):
            A = rest
    return A

def decide_graph(nodes, uses, weight, title=str):
    """Everything the rules decide: h, hubs, the arrows after hubs, the arrows kept, the references."""
    g = Graph(nodes, uses, weight, title)
    hubs, h, kept = choose_hubs(g)
    after_hubs = arrows_without(g.uses, set(hubs))
    arrows = relay_reduce(g, after_hubs)
    return dict(graph=g, nodes=g.nodes, uses=g.uses, h=h, hubs=hubs, kept=kept,
                after_hubs=after_hubs, arrows=arrows, references=g.uses - arrows)

def references_of(nodes, uses, weight, title=str):
    """The uses (a, b) drawn through references; every other use in `uses` between `nodes` is an arrow."""
    return decide_graph(nodes, uses, weight, title)['references']

# ---- a module's (or folder's) board --------------------------------------------------------------------

SAME, _ = common.edges_between(set(PROD))
NAMES = {(a, b): len(names) for a, b, names in common.USES}

def symbols(a, b):
    """How much file a uses file b: the number of b's symbols a names (the index's `names`)."""
    return NAMES.get((a, b), 0)

def board_uses(board):
    files = board_files(board)
    fs = set(files)
    return files, set((a, b) for a in files for b in SAME.get(a, []) if b in fs and b != a)

_cache = {}

def decide(board):
    if board not in _cache:
        files, E = board_uses(board)
        _cache[board] = decide_graph(files, E, symbols, ftitle)
    return _cache[board]

def references(board):
    """The same-board uses drawn through references: both directions of a pair that goes through them."""
    return set(decide(board)['references'])

def arrows(board):
    """The same-board uses drawn as arrows (a pair both ways appears as both of its directions)."""
    return set(decide(board)['arrows'])

# ---- a module's own board, when its folders have boards (Canvas's) -----------------------------------------

def folder_graph(m):
    """A module's folder boards as a graph: a folder uses another when one of its files uses one of the
    other's; the weight is how many file pairs do. The files on the module's own board are left out."""
    folders = set(common.folder_boards(m))
    pairs = collections.Counter()
    for a, b, _ in common.USES:
        if a[0] == m and b[0] == m:
            x, y = board_of(a), board_of(b)
            if x != y and x in folders and y in folders:
                pairs[(x, y)] += 1
    nodes = sorted(set(x for p in pairs for x in p))
    return nodes, set(pairs), lambda a, b: pairs.get((a, b), 0)

if __name__ == '__main__':
    import time
    t0 = time.time()
    total = kept = 0
    for b in common.boards_for(PROD):
        d = decide(b)
        g = d['graph']
        n, k = len(g.units(d['uses'])), len(g.units(d['arrows']))
        total += n; kept += k
        if n:
            print(f"{b:<20} {k:>3} of {n:>3} arrows  h={d['h']}  hubs: {', '.join(ftitle(x) for x in d['hubs']) or '-'}")
    print(f"{kept} of {total} same-board uses stay arrows; {time.time() - t0:.2f}s")
    for m in common.FOLDER_BOARDS:
        nodes, uses, w = folder_graph(m)
        d = decide_graph(nodes, uses, w)
        g = d['graph']
        print(f"{m}'s folders: {len(uses)} uses, {len(g.units(uses))} drawn; h={d['h']}; hubs {d['hubs']}; kept {d['kept']}; "
              f"{len(g.units(d['arrows']))} arrows")
