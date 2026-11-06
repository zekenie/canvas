"""A graph document, built: nodes and edges keyed by the code, every attribute passed through as given, warnings gathered.

    g = Graph()                                                          # the drawing's name is the runner's to give (settings, else the repository's)
    g.layout["mess"] = 0.1                                               # the render layer's options for the whole
    band = g.node("band:Core layer", "frame", {"title": "Core layer"}, layout={"rank": 0})
    core = g.node("module:Core", "subboard", {"title": "Core", "description": "Takes the money."}, in_=band)
    note = g.node("file:src/charge.py", "sticky-note", {"title": "charge.py", "is": ["type:File"]}, in_=core)
    other = g.node("file:src/refund.py", "sticky-note", {"title": "refund.py"}, in_=core)
    g.edge(note, other, {"text": "uses"}, layout={"weight": 2})          # between nodes (or their keys), never a node and its holder
    doc = g.finish()                                                     # {drawing?, layout?, nodes, edges, warnings}

The format is `canvas-digest`'s graph document (its reference/graph.md): a node is `key`, `in` (the key of the node that holds it),
`kind`, `props` (the app's attributes, as `canvas kinds` lists them for the kind) and `layout` (hints for the layout: `rank`,
`direct`, `public`); an edge is `from`, `to`, optional `key`, `props` and `layout`. The builder holds no rule about kinds,
attributes or titles: what it is given is what it writes, and the app says no to what it won't take. A value that names another
shape names it by key (`"is": ["type:File"]`, a mention `@[table:orders]` in a text: `lenskit.text.mention`).

A lens returns the finished document. `ingest` takes `warnings` off it and says them; the rest is what canvas-digest lays out."""


def key_of(node):
    """The key a node, or a key, stands for."""
    return node['key'] if isinstance(node, dict) else node


class Graph:
    """A graph document being built: `node` and `edge` add to it, `get` finds a node by its key, `warn` says what a lens could
    not do, `finish()` makes it the document. Nodes and edges are plain dicts, in the order they were made; a lens may change one
    (`node['props']['text'] = ...`) before it finishes."""

    def __init__(self, drawing=None, **layout):
        self.drawing = drawing
        self.layout = dict(layout)
        self.nodes, self.edges, self.warnings = [], [], []
        self.by_key = {}

    def warn(self, message):
        self.warnings.append(message)

    def get(self, key):
        """The node with that key (or None)."""
        return self.by_key.get(key_of(key))

    def node(self, key, kind, props=None, *, in_=None, layout=None, **more):
        """A node. `key` is a non-empty string no other node has and the same from run to run; `kind` any kind `canvas kinds`
        lists; `in_` the node (or key) of the shape that holds it; `props` a dict of attributes, with `more` (keywords) added to
        it, for the names Python allows; `layout` a dict of hints. Returns the node."""
        if not isinstance(key, str) or not key:
            raise ValueError(f"a node's key is a non-empty string, not {key!r}")
        if key in self.by_key:
            raise ValueError(f"two nodes have the key {key!r}: a key names one node (the same thing keeps its key from run to run)")
        node = {'key': key}
        if in_ is not None:
            node['in'] = key_of(in_)
        node['kind'] = kind
        merged = {**(props or {}), **more}
        if merged:
            node['props'] = merged
        if layout:
            node['layout'] = dict(layout)
        self.nodes.append(node)
        self.by_key[key] = node
        return node

    def edge(self, source, target, props=None, *, key=None, layout=None, **more):
        """An edge from one node to another, each as the node or its key. `props` and `more` are the arrow's attributes
        (`text`, `is`, `fieldValues`, `endRule`, ...); `key` is optional (an edge is told apart by its ends and its `is`);
        `layout` a dict of hints (`weight`, `direct`). Returns the edge."""
        edge = {'from': key_of(source), 'to': key_of(target)}
        if key is not None:
            edge['key'] = key
        merged = {**(props or {}), **more}
        if merged:
            edge['props'] = merged
        if layout:
            edge['layout'] = dict(layout)
        self.edges.append(edge)
        return edge

    def finish(self):
        """The document: `{drawing, layout, nodes, edges, warnings}` (`drawing` and `layout` only when set). Refuses, naming the
        key, a node whose `in` or an edge whose end names no node, and an `in` that runs in a circle: the structure, which the
        app can't be asked about; every other rule is the app's and the render layer's."""
        for n in self.nodes:
            if 'in' in n and n['in'] not in self.by_key:
                raise ValueError(f"the `in` of {n['key']!r} names {n['in']!r}, which no node has")
        for number, e in enumerate(self.edges):
            for end in ('from', 'to'):
                if e[end] not in self.by_key:
                    raise ValueError(f"the `{end}` of edge {number} ({e['from']!r} to {e['to']!r}) names {e[end]!r}, which no node has")
        for n in self.nodes:
            seen, at = {n['key']}, n
            while 'in' in at:
                at = self.by_key[at['in']]
                if at['key'] in seen:
                    raise ValueError(f"{n['key']!r} is held by itself, however far: `in` can't run in a circle")
                seen.add(at['key'])
        doc = {}
        if self.drawing is not None:
            doc['drawing'] = self.drawing
        if self.layout:
            doc['layout'] = dict(self.layout)
        doc.update(nodes=self.nodes, edges=self.edges, warnings=list(self.warnings))
        return doc
