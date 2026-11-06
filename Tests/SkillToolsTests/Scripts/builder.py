# Builds small graph documents with lenskit's `Graph` and prints what they are and what was refused, as JSON.
# usage: python3 -s -B builder.py SKILL    (SKILL: the canvas-ingest skill's folder, where lenskit is)
import json, sys
sys.path.insert(0, sys.argv[1])
from lenskit import Graph
from lenskit.text import mention, whole

def refused(call):
    try:
        call()
        return "NOT REFUSED"
    except ValueError as e:
        return str(e)

out = {}

# a document, as written: keys, `in` by key, props and layout passed through as given, nothing else added
g = Graph("shop", mess=0.1)
band = g.node("band:Core", "frame", {"title": "Core"}, layout={"rank": 0})
core = g.node("module:Core", "subboard", {"title": "Core", "description": "Takes the money."}, in_=band)
a = g.node("file:src/index.ts", "sticky-note", {"title": "index.ts", "is": ["type:File"], "fieldValues": {"lines": 3}}, in_=core)
b = g.node("file:lib/index.ts", "sticky-note", title="index.ts", color="blue", futureAttribute={"any": ["thing"]}, in_="module:Core")
g.edge(a, b, {"text": "uses"}, layout={"weight": 3})
g.edge("file:lib/index.ts", core, key="edge:back", is_not_special=True)
g.warn("a thing it could not do")
out["document"] = g.finish()
out["again"] = g.finish() == out["document"]
out["get"] = [g.get("module:Core") is core, g.get(core) is core, g.get("nowhere")]

# a node with no props and no layout has neither; None is a value like any other
g = Graph()
g.node("x", "frame")
g.node("y", "sticky-note", {"text": None})
out["bare"] = g.finish()

# titles are not the builder's: two nodes with one title are two nodes
g = Graph()
g.node("a", "sticky-note", {"title": "index.ts"})
g.node("b", "sticky-note", {"title": "index.ts"})
out["same_title"] = [n["props"]["title"] for n in g.finish()["nodes"]]

# kinds are not the builder's either
g = Graph()
g.node("k", "no-such-kind", {"anything": 1})
out["any_kind"] = g.finish()["nodes"][0]["kind"]

# refused: a key twice, a key that is not a string, an `in` or an end that names no node, an `in` in a circle
g = Graph()
g.node("a", "frame")
out["twice"] = refused(lambda: g.node("a", "frame"))
out["empty_key"] = refused(lambda: g.node("", "frame"))
out["not_a_string"] = refused(lambda: g.node(3, "frame"))
g = Graph()
g.node("a", "frame", in_="nowhere")
out["bad_in"] = refused(g.finish)
g = Graph()
g.node("a", "frame")
g.edge("a", "ghost")
out["bad_end"] = refused(g.finish)
g = Graph()
g.node("a", "frame", in_="b")
g.node("b", "frame", in_="a")
out["circle"] = refused(g.finish)
g = Graph()
g.node("a", "frame", in_="a")
out["self"] = refused(g.finish)

# a mention names a node by its key, escaped as the app reads one
out["mention"] = [mention("table:orders"), mention("file:src/[id].ts"), mention("a\\b"), mention("two  spaces")]
out["whole"] = whole("ok\udc80") == "ok�"
print(json.dumps(out, indent=1))
