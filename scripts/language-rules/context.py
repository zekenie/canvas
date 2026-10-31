"""What a rule sees, built from a board through `canvas query`: the shape, everything one step around it (up and down
its containers and along its edges), shrunk to a budget, and what each of the rule's chips finds. This is what the
feature would send the decision model, read from the app as the app has it.

A board is read once (`Snapshot`), every shape with the attributes a rule may read; a chip's query runs through the
query engine itself, with :scope (and :scope-start, :scope-end) written as the shape's id until the language has
those words, and is run once for each distinct query (a member's votes share their district's).
"""
import json
import subprocess
from collections import Counter, defaultdict


class Canvas:
    def __init__(self, cli, board):
        self.cli, self.board = cli, str(board)
        self.queries_run = 0

    def query(self, text, fields=None, limit=10000):
        args = [self.cli, "query", "--board", self.board, "--limit", str(limit)]
        for f in fields or []:
            args += ["--fields", f]
        args.append("-")
        p = subprocess.run(args, input=text, capture_output=True, text=True)
        self.queries_run += 1
        if p.returncode != 0:
            raise RuntimeError(f"canvas query {text!r}: {p.stderr.strip()[:500]}")
        return json.loads(p.stdout)


class Snapshot:
    """Every note, arrow and subboard of a file, with its attributes whole."""

    def __init__(self, canvas):
        self.canvas = canvas
        self.shapes = {}
        for kind, fields in (("sticky-note", ["text", "fieldValues", "is", "schema", "relationship"]),
                             ("arrow", ["is", "fieldValues", "text"]),
                             ("subboard", ["description"])):
            for row in canvas.query(kind, fields)["rows"]:
                row["props"] = row.pop("properties", {})
                self.shapes[row["id"]] = row
        self.by_title = defaultdict(list)
        for s in self.shapes.values():
            if s.get("title"):
                self.by_title[s["title"]].append(s)
        self.types = {s["title"]: s for s in self.shapes.values() if s["props"].get("schema") and s.get("title")}
        self.at = defaultdict(list)  # shape id -> arrows at it
        for s in self.shapes.values():
            c = s.get("connection")
            if c:
                self.at[c["from"]["id"]].append(s)
                self.at[c["to"]["id"]].append(s)
        self.on = defaultdict(list)  # (board, innermost container title) -> shapes there
        for s in self.shapes.values():
            self.on[self.place(s)].append(s)

    def place(self, s):
        return (s.get("board"), tuple(s.get("inside") or ()))

    # ------------------------------------------------------------------ types and rules

    def lineage(self, titles):
        """A shape's types and what they build on, as Types orders them (`TypeOrder.linearized`, C3): the list read
        latest first, so a later type is the more specific, and a type always before what it builds on, each once.
        (Round 2 walked the list depth first in its written order, which put a vintage listing's Vintage after Car
        and so, reversed, sent its rule first.)"""
        def merge(seqs):
            seqs = [list(s) for s in seqs if s]
            out = []
            while seqs:
                for s in seqs:
                    head = s[0]
                    if not any(head in t[1:] for t in seqs):
                        break
                else:
                    # No order (Employee given, then Person): drop the list's own order, never a type's before what
                    # builds on it, so Person never beats Employee.
                    heads = [s[0] for s in seqs if not any(s[0] in t[1:] for t in seqs[:-1])]
                    head = heads[0] if heads else seqs[0][0]
                out.append(head)
                seqs = [[x for x in s if x != head] for s in seqs]
                seqs = [s for s in seqs if s]
            return out

        def of(t, seen=()):
            if t not in self.types or t in seen:
                return []
            parents = [p for p in reversed(self.types[t]["props"].get("is") or []) if p in self.types]
            return [t] + merge([of(p, seen + (t,)) for p in parents] + [parents])

        latest_first = [t for t in reversed(titles) if t in self.types]
        return merge([of(t) for t in latest_first] + [latest_first])

    def schema(self, type_title):
        return json.loads(self.types[type_title]["props"]["schema"])

    def rules(self, shape):
        """Every rule along the shape's types, most general type first (so the more specific come last), each with
        the type it is on."""
        out = []
        for t in reversed(self.lineage(shape["props"].get("is") or [])):
            for r in (self.schema(t).get("properties", {}).get("$rules", {}).get("const") or []):
                out.append(dict(r, type=t))
        return out

    # ------------------------------------------------------------------ how a shape is shown

    def noun(self, s):
        if s["kind"] == "arrow":
            return "arrow"
        if s["kind"] == "subboard":
            return "subboard"
        return "type" if s["props"].get("schema") else "note"

    def full(self, s):
        """A shape in full: what it is, its title, words and values."""
        out = {"kind": self.noun(s)}
        if s.get("title"):
            out["title"] = s["title"]
        if s["props"].get("is"):
            out["is"] = s["props"]["is"]
        words = s["props"].get("text") or s["props"].get("description")
        if words:
            out["words"] = words
        if s["props"].get("fieldValues"):
            out["values"] = s["props"]["fieldValues"]
        return out

    def brief(self, s):
        """A shape by name: its title (an arrow by its ends) and types."""
        if s["kind"] == "arrow":
            c = s["connection"]
            out = {"from": c["from"].get("title", "untitled"), "to": c["to"].get("title", "untitled")}
        else:
            out = {"title": s.get("title", "untitled " + self.noun(s))}
        if s["props"].get("is"):
            out["is"] = s["props"]["is"]
        return out

    def counted(self, shapes):
        """Shapes as counts by type (or kind): {"Vote": 261, "Member": 17}."""
        c = Counter()
        for s in shapes:
            c[", ".join(s["props"].get("is") or []) or self.noun(s)] += 1
        return dict(c.most_common())


def shrink(group, shapes, budget, show, snap):
    """A group of neighbors at a level of detail: in full while the budget allows, else by name, else counted."""
    if not shapes:
        return None
    if budget == "small" or len(shapes) > {"small": 0, "medium": 40, "large": 80}[budget]:
        return {"count": len(shapes), "by type": snap.counted(shapes)}
    if budget == "medium":
        return [show(s, False) for s in shapes]
    return [show(s, True) for s in shapes]


def arrow_item(snap, arrow, side, detail):
    """Another arrow beside the one checked: its values and its far end (by name, or in full)."""
    c = arrow["connection"]
    far_id = c["to"]["id"] if side == "start" else c["from"]["id"]
    far = snap.shapes.get(far_id)
    out = {"to" if side == "start" else "from": (snap.full(far) if detail else snap.brief(far)) if far else "missing"}
    if arrow["props"].get("fieldValues"):
        out.update(arrow["props"]["fieldValues"])
    return out


def context(snap, s, budget="medium", today=None):
    """What a rule on `s` sees for free: the shape and one step around it, labeled by how each relates."""
    out = {}
    if today:
        out["today"] = today
    out["shape"] = snap.full(s)
    out["its types"] = [dict({"type": t}, words=snap.types[t]["props"].get("text") or "",
                             **({"builds on": snap.types[t]["props"]["is"]} if snap.types[t]["props"].get("is") else {}))
                        for t in snap.lineage(s["props"].get("is") or [])]
    board, inside = snap.place(s)
    out["in"] = ({"container": inside[-1], "path": list(inside)} if inside else {"board": "the board's top level"})
    if s["kind"] == "arrow":
        c = s["connection"]
        start, end = snap.shapes.get(c["from"]["id"]), snap.shapes.get(c["to"]["id"])
        out["starts at"] = snap.full(start) if start else "missing"
        out["ends at"] = snap.full(end) if end else "missing"
        mine = set(s["props"].get("is") or [])
        for side, end_shape, label in (("start", start, "beside it at its start"), ("end", end, "beside it at its end")):
            if not end_shape:
                continue
            others = [a for a in snap.at[end_shape["id"]] if a["id"] != s["id"] and set(a["props"].get("is") or []) & mine
                      and a["connection"]["from" if side == "start" else "to"]["id"] == end_shape["id"]]
            g = shrink(label, others, budget, lambda a, d: arrow_item(snap, a, side, d), snap)
            if g is not None:
                out[label + f" (other {', '.join(sorted(mine))} arrows at {end_shape.get('title', 'it')})"] = g
    else:
        edges = snap.at[s["id"]]
        if edges:
            out["along its edges"] = [arrow_item(snap, a, "start" if a["connection"]["from"]["id"] == s["id"] else "end", budget == "large")
                                      for a in edges]
    siblings = [x for x in snap.on[snap.place(s)] if x["id"] != s["id"] and x["kind"] != "arrow"]
    if siblings:
        g = shrink("beside it", siblings, budget, lambda x, d: snap.full(x) if d else snap.brief(x), snap)
        out["beside it, in the same place"] = g
    if s["kind"] == "subboard":
        held = [x for x in snap.shapes.values() if x.get("board") == s["id"]]
        out["holds"] = shrink("holds", held, budget, lambda x, d: snap.full(x) if d else snap.brief(x), snap)
    return out


def scoped(query, s):
    """A chip's query with :scope written as the shape's id (and an arrow's ends through it)."""
    sid = "#" + s["id"]
    return (query.replace(":scope-start", f":start-of({sid})").replace(":scope-end", f":end-of({sid})")
            .replace(":scope", sid))


class Chips:
    """What each chip finds, run through the query engine once per distinct query."""

    def __init__(self, snap, limit=60):
        self.snap, self.limit, self.kept = snap, limit, {}

    def found(self, query, s):
        q = scoped(query, s)
        if q not in self.kept:
            rows = self.snap.canvas.query(q, ["text", "fieldValues", "is", "description"], limit=self.limit + 1)
            shapes = []
            for r in rows["rows"]:
                r["props"] = r.pop("properties", {})
                shapes.append(r)
            self.kept[q] = (shapes, rows["count"])
        shapes, count = self.kept[q]
        listed = [self.snap.full(x) for x in shapes[:self.limit]]
        if count > len(listed):
            listed.append({"and": f"{count - len(listed)} more"})
        return q, listed
