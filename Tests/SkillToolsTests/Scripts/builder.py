# Builds small digests with lenskit's `Digest` and prints what they are and what was refused, as JSON.
# usage: python3 -s -B builder.py SKILL    (SKILL: the canvas-ingest skill's folder, where lenskit is)
import json, sys
sys.path.insert(0, sys.argv[1])
from lenskit import Digest, Titles

def refused(call):
    try:
        call()
        return "NOT REFUSED"
    except ValueError as e:
        return str(e)

out = {}
a, b, c = {"title": "A"}, {"title": "B"}, {"title": "C"}

# a title is given out once in its container, case aside and spaces folded, and may repeat in another
said = []
titles = Titles(said.append)
out["container"] = [titles.claim("x", "index.ts", within=a), titles.claim("y", "index.ts", within=b), titles.claim("z", "Index.ts", within=a),
                    titles.claim("w", "  index.ts ", "other.ts", within=a)]
out["container_said"] = said

# with no container, one scope for all: the digest's titles each given out once, as before
said = []
titles = Titles(said.append)
out["whole"] = [titles.claim("x", "Core"), titles.claim("y", "core", "core (layer)"), titles.claim("z", "CORE"), titles.claim("w", "Core")]
out["whole_said"] = said
out["whole_taken"] = sorted(titles.taken)

# alone: the title is the digest's, in every container, whichever claim comes first
said = []
titles = Titles(said.append)
out["alone"] = [titles.claim("the card Core", "Core", alone=True), titles.claim("band", "core", "core (layer)", within=a), titles.claim("frame", "CORE", "x", within=b),
                titles.claim("card2", "Core", "Core (2)", alone=True)]
out["alone_said"] = said
out["alone_after"] = [titles.claim("note", "Shared", within=a), titles.claim("card", "shared", "shared (card)", alone=True)]

# type: unique among types in any container, and no matter to a shape that is no type
said = []
titles = Titles(said.append)
out["types"] = [titles.claim("t1", "Table", within=a, type=True), titles.claim("n", "Table", within=b), titles.claim("t2", "TABLE", "TABLE (type)", within=c, type=True)]
out["types_said"] = said

# within is a node, or the title of the one node that has it
d = Digest("by title")
band = d.frame("Band")
one, two = d.frame("One", band), d.frame("Two", band)
d.frame("Dup", one)
d.frame("Dup", two)
out["by_title"] = [d.claim("c", "x", within="One"), d.claim("c", "x", within="Two"), d.claim("c", "x", within="One")]
out["unknown"] = refused(lambda: d.claim("c", "x", within="Nowhere"))
out["ambiguous"] = refused(lambda: d.claim("c", "x", within="Dup"))

# titles that are all unique: the digest is as it was written, whether a lens named a node by its title or passed the node
d = Digest("plain")
frame = d.frame("F", rank=0)
n = d.note("N", "F", "words", source="n.py")
m = d.note("M", frame)
d.edge("N", frame)
d.edge(m, n, 2)
out["plain"] = d.finish()

# a title two nodes have: an id for each, and every reference to either is its id
d = Digest("shop")
top = d.frame("Top", rank=0)
app = d.subboard("app", top, "App")
lib = d.subboard("lib", top, "Lib")
f1 = d.note(d.claim("f", "index.ts", within=app), app, "one", source="app/index.ts")
f2 = d.note(d.claim("f", "index.ts", within=lib), lib, "two", source="lib/index.ts")
only = d.note("Only", lib, "three")
d.edge(f1, f2, 2)
d.edge(f2, "Only")
d.edge("Only", f1, text="back")
d.edge(only, lib)
done = d.finish()
out["digest"] = done
out["again"] = d.finish() == done

# refused: a title several nodes have, named by that string; a node of another digest; two types of one title
d = Digest("bad")
p, q = d.frame("P"), d.frame("Q")
d.note("Same", p)
d.note("Same", q)
d.edge("Same", "P")
out["ambiguous_ref"] = refused(d.finish)
d = Digest("foreign")
d.note("Here")
d.edge(Digest("other").note("Elsewhere"), "Here")
out["foreign"] = refused(d.finish)
d = Digest("types")
p, q = d.frame("P"), d.frame("Q")
d.note("Table", p, schema={"type": "object"})
d.note("Table", q, schema={"type": "object"})
out["two_types"] = refused(d.finish)

# an id a lens gave stays; a title that is another node's id needs one; ids that would be one get a number
d = Digest("ids")
p, q = d.frame("P"), d.frame("Q")
a1 = d.note("X", p, id="mine")
a2 = d.note("X", q)
a3 = d.note("mine", q)
a4 = d.note("Y", q, id="Y  in P")
a5 = d.note("Y", p)
d.edge(a1, a2)
d.edge(a3, a4)
d.edge(a2, a5)
out["ids"] = [[node["title"], node.get("id", "-"), node.get("in", "-")] if "in" in node else [node["title"]] for node in d.finish()["nodes"]]
out["id_edges"] = [[e["from"], e["to"]] for e in d.edges]

# ids sort as titles do: of two nodes whose titles differ, the smaller title has the smaller key (its id, else its title), so a
# row the digest orders by key stays in title order (printable titles, which have spaces folded, as the digest's own are)
import random
rng = random.Random(7)
alphabet = [chr(code) for code in range(0x20, 0x7f)] + list("éüß…λ中")
def made():
    return " ".join("".join(rng.choice(alphabet) for _ in range(rng.randint(1, 5))).split()) or "x"
broken = 0
for _ in range(60):
    d = Digest("order")
    frames = [d.frame(made()) for _ in range(3)]
    for _ in range(40):
        d.note(made(), rng.choice(frames))
    d.finish()
    keys = [(node["title"], node.get("id", node["title"])) for node in d.nodes if node["kind"] == "sticky-note"]
    broken += sum(1 for a in keys for b in keys if a[0] < b[0] and not a[1] < b[1])
out["order_broken"] = broken
print(json.dumps(out, indent=1))
