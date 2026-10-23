"""A digest, built: nodes and edges added by title, every title given out once, warnings gathered into the digest.

    d = Digest("My system")
    band = d.claim("the band Core", "Core", "Core (layer)")        # a title no other shape has (reworded, warned, if it must)
    d.frame(band, rank=0)                                          # extra fields go into the node as they are
    d.subboard("Billing", band, text="Takes the money.", source="services/billing")
    d.note("charge.py", "Billing", "def charge()", source="services/billing/charge.py")
    d.edge("charge.py", "Billing", weight=2)
    digest = d.finish()                                            # {title, nodes, edges, warnings}

A lens returns the finished digest. `ingest` takes `warnings` off it and says them; the rest is the digest canvas-digest
lays out (its reference/graph.md has the format)."""

LONGEST = 80                       # a title's most characters, as the digest counts them


def fold(title):
    """A title as the digest tells titles apart: spaces folded, case aside."""
    return ' '.join(title.split()).lower()


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
    """Every shape's title, given out once. A title another shape has (spaces folded, case aside), or one over the
    longest a title may be, gives way: to the next it is offered, then to a number after the last. Each is said through
    `warn`; none stops the run."""

    def __init__(self, warn):
        self.taken = set()
        self.warn = warn

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
            self.warn(f"{whole(what)} is titled \"{title}\": {why}")
        self.taken.add(fold(title))
        return title


class Digest:
    def __init__(self, title):
        self.title = title
        self.nodes, self.edges, self.warnings = [], [], []
        self.titles = Titles(self.warn)

    def warn(self, message):
        self.warnings.append(message)

    def claim(self, what, wanted, *others, most=LONGEST):
        """The title `wanted` for `what` (said in a warning), or the first of `others`, then a numbered one, that no
        other shape has. Offer the shapes that matter most first: they keep their names."""
        return self.titles.claim(what, wanted, *others, most=most)

    def add(self, title, kind, parent=None, text=None, **extra):
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
        edge = {'from': source, 'to': target}
        if weight is not None:
            edge['weight'] = weight
        edge.update(extra)
        self.edges.append(edge)
        return edge

    def finish(self):
        return {'title': self.title, 'nodes': self.nodes, 'edges': self.edges, 'warnings': list(self.warnings)}
