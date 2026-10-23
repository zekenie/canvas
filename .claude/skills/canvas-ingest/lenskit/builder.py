"""A digest, built: nodes and edges, every title given out once in the container that holds it, shapes naming each other by
node, warnings gathered into the digest.

    d = Digest("My system")
    band = d.frame(d.claim("the band Core", "Core", "Core (layer)"), rank=0)
    billing = d.subboard("Billing", band, text="Takes the money.", source="services/billing")
    title = d.claim("charge.py", "charge.py", within=billing)       # a title no other shape in Billing has (reworded, warned, if it must)
    charge = d.note(title, billing, "def charge()", source="services/billing/charge.py")
    d.edge(charge, billing, weight=2)                                # between nodes (or their titles)
    digest = d.finish()                                              # {title, nodes, edges, warnings}

A lens returns the finished digest. `ingest` takes `warnings` off it and says them; the rest is the digest canvas-digest lays out
(its reference/graph.md has the format). A title is unique among the nodes in one container; where two nodes in different
containers have the same title, `finish()` gives each an `id` and writes every `in`, `from` and `to` that names one as that id."""

LONGEST = 80                       # a title's most characters, as the digest counts them


def fold(title):
    """A title as the digest tells titles apart within a container: spaces folded, case aside."""
    return ' '.join(title.split()).lower()


def spaced(title):
    """A title as the digest matches a reference to it (`in`, `from`, `to`): spaces folded, case kept."""
    return ' '.join(title.split())


def units(title):
    return len(title.encode('utf-16-le', 'surrogatepass')) // 2      # the digest's count: UTF-16 units


def whole(title):
    """A name as a title can hold it: half a character (a file's name that isn't UTF-8 is read with those) reads as
    U+FFFD, which is what writing it to a script would make of it."""
    return ''.join('�' if 0xD800 <= ord(ch) <= 0xDFFF else ch for ch in title)


def clip(title, most):
    """A title of at most `most` characters: one over keeps its end, which is what tells it apart, behind an ellipsis."""
    if units(title) <= most:
        return title
    while units(title) > most - 1:
        title = title[1:]
    return '…' + title


class Titles:
    """Every shape's title, given out once in the container that will hold the shape (the nodes with the same `in`; the top of
    the first board is one container). A title another shape of the container has (spaces folded, case aside), or one over the
    longest a title may be, gives way: to the next it is offered, then to a number after the last. Each is said through `warn`;
    none stops the run.

    A claim that passes no `within` is at the top of the first board, so a lens that never says where a shape goes has every
    title given out once in the whole digest. Two further kinds of claim reach beyond a container:

    - `alone`: the title is the digest's alone. No other shape has it in any container, and none claimed later may. For a shape
      a text mentions (`@[Title]` names a shape by its title alone, wherever it is), or a query names bare.
    - `type`: the shape is a type (a note with a `schema`). Its title is given out once among the digest's types, in whatever
      container each is: `is` names a type by its title. A shape that is not a type may have the title.

    `Titles` knows no nodes: a container is whatever `within` says it is (`Digest.claim` takes the node itself, or its title where
    that is unique, and passes the node)."""

    def __init__(self, warn):
        self.taken = set()               # the titles given out at the top of the first board (within=None), folded
        self.inside = {}                 # a container's key: (the container, the titles given out in it)
        self.alone = {}                  # the titles kept for one shape in the whole digest: the shape's name for it
        self.types = set()               # the titles of types
        self.anywhere = set()            # every title given out, in any container
        self.warn = warn

    def _scope(self, within):
        """(the titles given out in this container, its name for a warning)."""
        if within is None:
            return self.taken, None
        key = id(within) if isinstance(within, dict) else fold(within) if isinstance(within, str) else within
        if key not in self.inside:
            self.inside[key] = (within, set())              # the container is kept, so its id() is never another object's
        name = within.get('title') if isinstance(within, dict) else within if isinstance(within, str) else None
        return self.inside[key][1], name if isinstance(name, str) else None

    def _note(self, scope, folded, alone, type, what):
        if folded:
            scope.add(folded)
            self.anywhere.add(folded)
            if alone:
                self.alone[folded] = what
            if type:
                self.types.add(folded)

    def claim(self, what, wanted, *others, within=None, most=LONGEST, alone=False, type=False):
        scope, container = self._scope(within)

        def free(t):
            f = fold(t)
            return bool(f) and f not in scope and f not in self.alone and not (alone and f in self.anywhere) and not (type and f in self.types)

        offered = [whole(wanted), *(whole(o) for o in others)]
        title = next((t for t in (clip(o, most) for o in offered) if free(t)), None)
        n = 2
        while title is None:
            numbered = f" ({n})"
            t = clip(offered[-1], most - len(numbered)) + numbered
            title, n = (t if free(t) else None), n + 1
        if title != wanted:
            first = fold(offered[0])
            if title == offered[0]:
                why = "its name isn't whole text"
            elif title == clip(offered[0], most):
                why = f"its name is over {most} characters"
            elif not first:
                why = "it has no name"
            elif first in self.alone and not alone:
                why = f"\"{offered[0]}\" is {self.alone[first]}'s title, which no other shape may have"
            elif first in scope:
                why = f"\"{offered[0]}\" is another shape's title in \"{container}\" too" if container else f"\"{offered[0]}\" is another shape's title too"
            elif type and first in self.types:
                why = f"\"{offered[0]}\" is another type's title too"
            else:
                why = f"\"{offered[0]}\" is another shape's title too"
            self.warn(f"{whole(what)} is titled \"{title}\": {why}")
        self._note(scope, fold(title), alone, type, whole(what))
        return title


class Digest:
    """A digest being built: `frame`, `subboard`, `note` and `add` make the nodes (dicts, in the order they are made), `edge` the edges,
    `claim` gives out titles, `warn` says what a lens could not do, and `finish()` makes it the digest."""

    def __init__(self, title):
        self.title = title
        self.nodes, self.edges, self.warnings = [], [], []
        self.titles = Titles(self.warn)

    def warn(self, message):
        self.warnings.append(message)

    def claim(self, what, wanted, *others, within=None, most=LONGEST, alone=False, type=False):
        """The title `wanted` for `what` (said in a warning), or the first of `others`, then a numbered one, that no other shape
        in the same container has. Offer the shapes that matter most first: they keep their names.

        `within` is the node that will hold the shape: the dict `add`, `frame`, `subboard` or `note` returned, or its title where
        that title is unique. None is the top of the first board. `alone` makes the title the digest's alone (a shape a text
        mentions), `type` makes it unique among types (a note with a `schema`)."""
        return self.titles.claim(what, wanted, *others, within=self._container(within), most=most, alone=alone, type=type)

    def _container(self, within):
        """The node `within` stands for, for a claim: itself, or the one node that has that title."""
        if not isinstance(within, str):
            return within
        found = [n for n in self.nodes if isinstance(n, dict) and isinstance(n.get('title'), str) and spaced(n['title']) == spaced(within)]
        if len(found) != 1:
            raise ValueError(f"within \"{within}\": " + (f"{len(found)} nodes have that title, so it names none of them: pass the node itself" if found else
                             "no node has that title: add the container first (a title names the one node that has it), or pass None for the top of the first board"))
        return found[0]

    def add(self, title, kind, parent=None, text=None, **extra):
        """A node. `parent` is the frame or subboard that holds it, as the node `add` returned for it or as its title (or id);
        `finish()` writes it as the digest names a node."""
        node = {'title': title, 'kind': kind}
        if parent:
            node['in'] = parent
        if text:
            node['text'] = text
        node.update(extra)
        self.nodes.append(node)
        return node

    def frame(self, title, parent=None, **extra):
        return self.add(title, 'frame', parent, None, **extra)

    def subboard(self, title, parent=None, text=None, **extra):
        return self.add(title, 'subboard', parent, text, **extra)

    def note(self, title, parent=None, text=None, **extra):
        return self.add(title, 'sticky-note', parent, text, **extra)

    def edge(self, source, target, weight=None, **extra):
        """An edge between two nodes, each as the node `add` returned or as its title (or id)."""
        edge = {'from': source, 'to': target}
        if weight is not None:
            edge['weight'] = weight
        edge.update(extra)
        self.edges.append(edge)
        return edge

    def finish(self):
        """The digest: {title, nodes, edges, warnings}. First the nodes are made to name each other as the digest reads names:
        every node whose title another node has gets an `id` (unless the lens gave it one), and every `in`, `from` and `to` that
        is a node is written as its id, else its title. A digest whose titles are all unique comes out as it was written."""
        self._settle()
        return {'title': self.title, 'nodes': self.nodes, 'edges': self.edges, 'warnings': list(self.warnings)}

    def _settle(self):
        nodes = [n for n in self.nodes if isinstance(n, dict)]
        edges = [e for e in self.edges if isinstance(e, dict)]
        held = {id(n): n for n in nodes}
        titled, named = {}, {}                                  # by title as a reference matches it (spaces folded, case kept), and by id
        for n in nodes:
            if isinstance(n.get('title'), str) and spaced(n['title']):
                titled.setdefault(spaced(n['title']), []).append(n)
            if isinstance(n.get('id'), str) and n['id'].strip():
                named.setdefault(n['id'], []).append(n)

        # types: `is` names one by its title, which the digest takes for one only
        types = {}
        for n in nodes:
            if n.get('schema') is not None and isinstance(n.get('title'), str) and spaced(n['title']):
                types.setdefault(spaced(n['title']), []).append(n)
        for t, same in types.items():
            if len(same) > 1:
                raise ValueError(f"{len(same)} types are called \"{t}\": a type's title is unique in the whole digest, since `is` names a type by "
                                 f"its title. Claim a type's title with type=True, which gives it out once among the types")

        def show(reference):
            return reference.get('title') if isinstance(reference, dict) else reference

        def find(reference, whose):
            """The node a reference names: a node itself; a string by its id, else by its title (an error if several nodes have it);
            None for a string that names no node (`check` refuses that). `whose` says whose reference it is, for an error."""
            if isinstance(reference, dict):
                if id(reference) not in held:
                    raise ValueError(f"{whose()}: \"{show(reference)}\" is a node this digest doesn't have; pass a node `add`, `frame`, "
                                     f"`subboard` or `note` returned for it")
                return reference
            if not isinstance(reference, str):
                return None
            if reference in named:
                if len(named[reference]) > 1:
                    raise ValueError(f"{whose()}: \"{reference}\" is the id of {len(named[reference])} nodes, and an id is unique")
                return named[reference][0]
            same = titled.get(spaced(reference), [])
            if len(same) > 1:
                raise ValueError(f"{whose()}: \"{spaced(reference)}\" is the title of {len(same)} nodes, so it names none of them; pass the node itself "
                                 f"(what `add`, `frame`, `subboard` or `note` returned), or give the nodes ids and name one by its id")
            return same[0] if same else None

        # what each node is in, and the references that are nodes (written as names once ids are given)
        parent_of, named_by_node = {}, []
        for n in nodes:
            reference = n.get('in')
            if reference in (None, ''):
                continue
            target = find(reference, lambda n=n: f"the `in` of \"{show(n)}\"")
            parent_of[id(n)] = target if target is not None else reference
            if isinstance(reference, dict):
                named_by_node.append((n, 'in', target))
        for number, e in enumerate(edges):
            for end in ('from', 'to'):
                target = find(e.get(end), lambda e=e, end=end, number=number: f"the `{end}` of edge {number} (\"{show(e.get('from'))}\" to \"{show(e.get('to'))}\")")
                if isinstance(e.get(end), dict):
                    named_by_node.append((e, end, target))

        # ids: a node whose title another node has can't be named by it, so it is named by an id that says where it is: its title,
        # then the containers it is in as `a > b` (the digest's own way of telling such nodes apart, which sorts by title)
        used = set(named)

        def containers(n):
            out, cur, seen = [], parent_of.get(id(n)), {id(n)}
            while cur is not None:
                if isinstance(cur, str):
                    out.append(spaced(cur))
                    break
                if id(cur) in seen:
                    break
                seen.add(id(cur))
                out.append(spaced(cur['title']) if isinstance(cur.get('title'), str) else '')
                cur = parent_of.get(id(cur))
            return ' > '.join(reversed(out))

        for n in nodes:
            title = spaced(n['title']) if isinstance(n.get('title'), str) else ''
            if not title or n.get('id') is not None or not (len(titled[title]) > 1 or title in named):
                continue
            base = f"{title}  in {containers(n) or 'the first board'}"
            given, number = base, 2
            while given in used:
                given, number = f"{base} ({number})", number + 1
            used.add(given)
            items = list(n.items())
            n.clear()
            for key, value in items:                          # the id comes after the title, where the format lists it
                n[key] = value
                if key == 'title':
                    n['id'] = given
            if 'id' not in n:
                n['id'] = given
        for holder, key, target in named_by_node:
            given = target.get('id')
            holder[key] = given if isinstance(given, str) and given.strip() else target['title']
