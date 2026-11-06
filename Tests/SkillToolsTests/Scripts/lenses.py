# Runs the default lens and the two worked examples' lenses through the runner (twice, isolated) on their scans and checks the
# graph documents they make; prints "ok" and a summary, or the first thing wrong.
# usage: python3 -s -B lenses.py SKILL SCRATCH    (SKILL: the canvas-ingest skill's folder; SCRATCH: an empty folder to work in)
import json, os, re, shutil, subprocess, sys
skill, scratch = os.path.abspath(sys.argv[1]), os.path.abspath(sys.argv[2])
sys.path.insert(0, skill)
from lenskit import Scan, default

def check(ok, message):
    if not ok:
        print("WRONG:", message)
        sys.exit(1)

def git(cwd, *args):
    subprocess.run(["git", "-C", cwd, "-c", "user.email=t@t", "-c", "user.name=t", *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)

def run(repo, scan, out, lens=None, *extra):
    cmd = ["/usr/bin/python3", "-s", "-B", os.path.join(skill, "runner/run.py"), repo, scan, out, "--drawing-default", "repo", *extra]
    if lens:
        cmd += ["--lens", lens]
    done = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    check(done.returncode == 0, done.stdout + done.stderr)
    return json.load(open(out)), done.stderr

def well_formed(doc, label):
    keys = [n["key"] for n in doc["nodes"]]
    check(len(keys) == len(set(keys)), f"{label}: a key twice")
    for n in doc["nodes"]:
        check(set(n) <= {"key", "in", "kind", "props", "layout"}, f"{label}: {n['key']} has {sorted(n)}")
        check("in" not in n or n["in"] in keys, f"{label}: {n['key']} is in {n.get('in')}")
        check("title" in n.get("props", {}), f"{label}: {n['key']} has no title")
        props = n.get("props", {})
        for ref in props.get("is", []):
            check(ref in keys and "schema" in doc_node(doc, ref)["props"], f"{label}: {n['key']} is {ref}, which is no type")
        for text in (props.get("text"), props.get("description")):
            for ref in re.findall(r"@\[([^\]]*)\]", text or ""):
                check(ref in keys, f"{label}: {n['key']} mentions {ref}, which is no node")
    for e in doc["edges"]:
        check(set(e) <= {"from", "to", "key", "props", "layout"} and e["from"] in keys and e["to"] in keys, f"{label}: edge {e}")
        for ref in e.get("props", {}).get("is", []):
            check(ref in keys, f"{label}: an edge is {ref}")

def doc_node(doc, key):
    return next(n for n in doc["nodes"] if n["key"] == key)

out = {}

# the default lens on the bookshelf's scan: keyed by the code, titled by its names, two index.ts both index.ts
bookshelf = os.path.join(skill, "examples/bookshelf")
scan = Scan.load(os.path.join(bookshelf, "scan.json"))
plain = default.digest(scan, "bookshelf")
doc, _ = run(skill, os.path.join(bookshelf, "scan.json"), os.path.join(scratch, "default.json"))
check(doc["drawing"] == "repo" and "title" not in doc, "the runner names the drawing")
well_formed(doc, "default")
for f in scan.files.values():
    n = doc_node(doc, f"file:{f['path']}")
    check(n["props"]["title"] == f["path"].rpartition("/")[2] and n["kind"] == "sticky-note", f"default: {f['path']}")
indexes = [n for n in doc["nodes"] if n["props"]["title"] == "index.ts"]
check(len(indexes) == 3 and len({n["key"] for n in indexes}) == 3, "default: three index.ts, three keys")
check(all(m.startswith("module:") for m in [n["key"] for n in doc["nodes"] if n["kind"] == "subboard"]), "default: cards are module:")
check(any(e.get("layout", {}).get("weight") for e in doc["edges"]), "default: weights are layout")
check(json.dumps(plain["nodes"]) == json.dumps(doc["nodes"]) and "drawing" not in plain, "default: the runner adds only the drawing and the dial")
out["default"] = [len(doc["nodes"]), len(doc["edges"])]

# the dial and the name from the runner
doc, _ = run(skill, os.path.join(bookshelf, "scan.json"), os.path.join(scratch, "dial.json"), None, "--drawing", "mine", "--mess", "0.5", "--ranks", "columns")
check(doc["drawing"] == "mine" and doc["layout"] == {"mess": 0.5, "ranks": "columns"}, f"dial: {doc.get('layout')}")

# overrides: bands, groups (with and without a key), folder boards, purposes
scan = Scan.load(os.path.join(bookshelf, "scan.json"))
mods = scan.production
custom = default.digest(scan, "bookshelf", drawing="named", bands=[("Apps", mods[:1]), ("Rest", mods[1:])],
                        groups={mods[0]: [("Mine", ["src/index.ts"], [], "group:mine"), ("Other", [], [])]})
check(custom["drawing"] == "named" and doc_node(custom, "group:mine")["props"]["title"] == "Mine", "overrides")

# collapsing keeps keys apart
files = {("M", f"d/f{i}.ts"): {} for i in range(6)}
check(len(default.collapse(files, most=3)) == 1 and default.collapse(files) == {}, "collapse")

# the examples through the runner: copied into git repositories of their own, as the tests and a user do
for name in ("bookshelf", "orders"):
    repo = os.path.join(scratch, name)
    shutil.copytree(os.path.join(skill, "examples", name), repo, ignore=shutil.ignore_patterns("scan.json"))
    subprocess.run(["git", "init", "-q", repo], check=True)
    git(repo, "add", "-A")
    git(repo, "commit", "-qm", "x")
    doc, said = run(repo, os.path.join(skill, "examples", name, "scan.json"), os.path.join(scratch, name + ".json"), os.path.join(repo, ".canvas/lens.py"))
    well_formed(doc, name)
    check("File" in [n["props"]["title"] for n in doc["nodes"] if n["key"].startswith("type:")], f"{name}: the type File")
    check(all(doc_node(doc, f"file:{f['path']}")["props"]["is"] == ["type:File"] for f in Scan.load(os.path.join(skill, "examples", name, "scan.json")).files.values()
              if ("services/" in f["path"] or name == "bookshelf")), f"{name}: files are Files")
    out[name] = [len(doc["nodes"]), len(doc["edges"])]
    if name == "orders":
        keys = {n["key"] for n in doc["nodes"]}
        check("workflow:services/orders/src/workflows/checkout.ts#checkoutWorkflow" in keys and "table:orders" in keys
              and "lambda:services/billing/serverless.yml#paymentWebhook" in keys, "orders: keys from the code")
        frames = [n for n in doc["nodes"] if n["props"].get("is") == ["type:Collection"]]
        check(len(frames) >= 4 and all(n["kind"] == "frame" and n["props"]["fieldValues"]["holds"] for n in frames), "orders: typed frames")
        check(not said.strip().replace("\n", "") or "lens:" in said, said)
# the orders lens: functions that call each other each touch what both touch, whichever is read first
import importlib.util
spec = importlib.util.spec_from_file_location("orders_lens", os.path.join(skill, "examples/orders/.canvas/lens.py"))
orders_lens = importlib.util.module_from_spec(spec)
spec.loader.exec_module(orders_lens)
class FakeScan:
    files = {"f": {"path": "db/x.ts", "decls": [{"name": "a", "kind": "function", "visibility": "public", "line": 1},
                                                {"name": "b", "kind": "function", "visibility": "public", "line": 3}]}}
    uses = []
class FakeRepo:
    @staticmethod
    def read(path):
        return 'export function a() {\n  db.query("SELECT id FROM t1"); b();\n}\nexport function b() {\n  db.query("UPDATE t2 SET x = 1"); a();\n}\n'
for first in ("a", "b"):
    code = orders_lens.Code(FakeScan, FakeRepo)
    code.touches("db/x.ts", first, {"t1", "t2"}, print)
    for name in ("a", "b"):
        reads, writes = code.touches("db/x.ts", name, {"t1", "t2"}, print)
        check(list(reads) == ["t1"] and list(writes) == ["t2"], f"orders: {name} read after {first}: {reads} {writes}")
print("ok", json.dumps(out))
