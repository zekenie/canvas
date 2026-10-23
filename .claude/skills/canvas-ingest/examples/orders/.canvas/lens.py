"""The shop's lens: its services as boards, and the Temporal workflows and activities, the Lambdas and the Postgres tables as
types, so "which workflows write orders?" is a canvas query.

Everything is found by convention, through the scan and `repo` (the code at the commit drawn): workflows and activities by
their folders and `proxyActivities`, Lambdas by serverless.yml, tables by the migrations, and which table a function reads or
writes by the SQL in its body and in the functions it calls, followed through the scan's uses.

The conventions are the limits of this lens (the README lists them): what it does not read it passes over, and says so as a
`lens:` warning where it can tell, and nowhere where it cannot (a private helper that holds the SQL, an ORM).

The rules are the team's decisions, each named, with its reason and the round it came from. Change a rule only when its
reason has changed; a new request is a new rule. Python 3.9: no `match`, no `X | Y` types."""
import re

from lenskit import Digest, sql, yaml
from lenskit.text import as_text

# ---- the rules -----------------------------------------------------------------------------------------------------------

# Rule "services-are-folders": a service is a module of the scan whose path is under services/; packages/ hold what the
# services share and are not drawn. Why: the board is of what runs; the db package is how a service reaches a table, and
# shows up as the reads and writes it makes (round 1, confirmed by the team).
SERVICES = "services/"

# Rule "temporal-by-folder": a workflow is an exported function of a file in a workflows/ folder, an activity one of a file
# in an activities/ folder, and a workflow runs the activities it calls through `proxyActivities`, as
# `const { a, b } = proxyActivities(...)` or as `const acts = proxyActivities(...)` and `acts.a()`, the SDK imported by name
# or as a namespace (`wf.proxyActivities`). Why: every Temporal service here is laid out that way (round 1). A workflow file
# that mentions `proxyActivities` and runs no activity is warned.
WORKFLOWS, ACTIVITIES = "workflows", "activities"
PROXIED = r"(?:[A-Za-z_$][\w$]*\s*\.\s*)?proxy(?:Local)?Activities\b"
PROXY = re.compile(r"(?:const|let|var)\s*\{([^}]*)\}\s*=\s*" + PROXIED)
PROXY_NAMESPACE = re.compile(r"(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*" + PROXIED)
PROXY_MENTION = re.compile(r"\bproxy(?:Local)?Activities\b")

# Rule "task-queue-from-worker": a workflow's task queue is the `taskQueue` of its service's `Worker.create`. Why: the
# queue is how ops finds a workflow in Temporal's UI (round 1).
WORKER = re.compile(r"Worker\.create\(")
TASK_QUEUE = re.compile(r"taskQueue:\s*[\"'`]([^\"'`]+)[\"'`]")

# Rule "lambdas-from-serverless": a Lambda is a function of a serverless.yml, its code the export its handler names.
# Why: the Lambdas are declared there, not in the code (round 1).
SERVERLESS = "**/serverless.yml"
HANDLER_FILES = (".ts", ".js", ".mjs")

# Rule "tables-from-migrations": a table is what db/migrations/*.sql make of it, read in the files' order, so a column a
# later migration adds is on it. Why: the migrations are what the database is (round 1).
MIGRATIONS = "db/migrations/*.sql"

# Rule "tables-through-sql": a function reads the tables its SQL selects from or joins, and writes those it inserts into,
# updates or deletes from; it also reads and writes what the functions it calls do, followed through the scan's uses.
# Only SQL in a string counts: a string with no SELECT, INSERT, UPDATE or DELETE has none, and a table is taken only after
# one; EXTRACT(.. FROM ..), FOR UPDATE [OF ..], IS DISTINCT FROM and the names a WITH gives are no tables. Why: every
# service reaches Postgres through the db package's functions (round 1).
STRING = re.compile(r"`([^`]*)`|'((?:[^'\\\n]|\\.)*)'|\"((?:[^\"\\\n]|\\.)*)\"")
SQL_VERB = re.compile(r"\b(?:SELECT|INSERT|UPDATE|DELETE)\b", re.I)
TOUCH = re.compile(r"\b(INSERT\s+INTO|UPDATE|DELETE\s+FROM|FROM|JOIN)\s+\"?([A-Za-z_][\w.]*)\"?(\s*\()?", re.I)
NOT_A_TABLE = re.compile(r"\bEXTRACT\s*\([^)]*\)|\bFOR\s+(?:NO\s+KEY\s+)?(?:UPDATE|SHARE)\b(?:\s+OF\s+[\w.\", ]+)?|\bIS\s+(?:NOT\s+)?DISTINCT\s+FROM\b", re.I)
CTE = re.compile(r"(?:\bWITH\s+(?:RECURSIVE\s+)?|,\s*)\"?([A-Za-z_]\w*)\"?\s*(?:\([^)]*\)\s*)?AS\s*(?:NOT\s+)?(?:MATERIALIZED\s*)?\(", re.I)

# Rule "every-activity-is-run": an activity's "run by" row is Needed, so one no workflow runs is :incomplete. Why: the
# team wants activities left behind by a refactor found (round 1).
RUN_BY_NEEDED = True

# Rule "tables-on-the-root": the root has three frames, top to bottom: the services, the tables (Database: a frame called Tables
# gave draw's near-miss warning beside the type Table) and the types. Why: every service shares the tables, so they belong
# to none (round 1).
ROOT_FRAMES = ("Services", "Database", "Types")
SERVICES_FRAME, TABLES_FRAME, TYPES_FRAME = ROOT_FRAMES

# Rule "workflows-on-top": a service's board has a frame each for its workflows, activities and Lambdas, top to bottom.
# Why: a service is read from what starts work down to what does it (round 1).
SERVICE_FRAMES = ("Workflows", "Activities", "Lambdas")

# Rule "names-per-container": a title is given out once in the container that holds the shape, so two services may each have a
# workflow called `syncWorkflow`, and every service's board a frame `Workflows`. The digest tells such nodes apart by an id that
# `Digest.finish` gives (the title, then the containers it is in) and writes wherever one is named, so the lens names a node by
# the node `add` returned and never by a title it shares. Only the types' titles are unique across the digest, among the types,
# since `is` names a type by its title. Why: services repeat names as folders do, and a name reworded to be unique in the whole
# file (`syncWorkflow (billing)`) is one nobody wrote (round 3: "I need multiple nodes to have the same name without a validation
# error. Of course, they will be nested in frames that are unique, so their global path will be unique."). The code: the `within`
# of each claim in `digest`, and `type=True` on the types'.

# Rule "runs-are-arrows": a workflow's arrows to the activities it runs are drawn as arrows, never as pills beside it. Why:
# a workflow's steps read as a flow only when the lines are there (round 2: the first drawing showed checkout's three steps
# as pills).
RUNS_DIRECT = True

# ---- the types ----------------------------------------------------------------------------------------------------------

STRING_FIELD = {"type": "string"}
LIST_OF_STRINGS = {"type": "array", "items": {"type": "string"}}
TYPES = {
    "Workflow": ("A Temporal workflow: its name, the file it is in and its task queue.",
                 {"name": STRING_FIELD, "file": STRING_FIELD, "taskQueue": STRING_FIELD}),
    "Activity": ("A Temporal activity: its name and the file it is in.", {"name": STRING_FIELD, "file": STRING_FIELD}),
    "Lambda": ("An AWS Lambda: its name in serverless.yml, its handler and what invokes it.",
               {"name": STRING_FIELD, "handler": STRING_FIELD, "events": LIST_OF_STRINGS}),
    "Table": ("A Postgres table: its name, its columns as the migrations leave them, and the migrations that made it.",
              {"name": STRING_FIELD, "columns": LIST_OF_STRINGS, "migrations": LIST_OF_STRINGS}),
}
RELATIONSHIPS = {
    "runs": ("A workflow runs an activity, at a step of its own.", {"step": {"type": "integer"}}),
    "reads": ("An activity or a Lambda reads a table, through these functions.", {"via": LIST_OF_STRINGS}),
    "writes": ("An activity or a Lambda writes a table, through these functions.", {"via": LIST_OF_STRINGS}),
}
# Each end: (from, to, the row it gives the notes at its far side, its rule)
ENDS = [("Workflow", "runs", "runs", None), ("runs", "Activity", "run by", {"needed": True} if RUN_BY_NEEDED else None),
        ("Activity", "reads", "reads", None), ("Lambda", "reads", "reads", None), ("reads", "Table", "read by", None),
        ("Activity", "writes", "writes", None), ("Lambda", "writes", "writes", None), ("writes", "Table", "written by", None)]


def schema(properties):
    return {"type": "object", "properties": properties, "required": ["name"] if "name" in properties else []}


# ---- reading the code ---------------------------------------------------------------------------------------------------

class Code:
    """The scan's files and functions, read through `repo`: each function's body, its doc, and the functions it calls."""

    def __init__(self, scan, repo):
        self.scan, self.repo = scan, repo
        self.by_path = {f["path"]: f for f in scan.files.values()}
        self.texts = {}
        self.uses = {}                  # a file's path: [(the path of a file it uses, the names it uses)]
        for (a, b, names) in scan.uses:
            if a in scan.files and b in scan.files:
                self.uses.setdefault(scan.files[a]["path"], []).append((scan.files[b]["path"], names))
        self.memo = {}

    def text(self, path):
        if path not in self.texts:
            self.texts[path] = self.repo.read(path)
        return self.texts[path]

    def functions(self, path):
        """The file's exported functions, in its order: [(name, line)]."""
        return [(d["name"], d["line"]) for d in self.by_path[path]["decls"] if d["kind"] == "function" and d["visibility"] == "public"]

    def body(self, path, name):
        """A declaration's lines: from its line to the next declaration's, or the end of the file."""
        lines = self.text(path).split("\n")
        starts = sorted(d["line"] for d in self.by_path[path]["decls"])
        line = next(d["line"] for d in self.by_path[path]["decls"] if d["name"] == name)
        end = next((s for s in starts if s > line), len(lines) + 1)
        return "\n".join(lines[line - 1:end - 1])

    def doc(self, path, line):
        """The first sentence of the JSDoc comment over a declaration (one line or several), if it has one."""
        lines = self.text(path).split("\n")
        end = line - 2
        if end < 0 or not lines[end].strip().endswith("*/"):
            return ""
        start = end
        while start >= 0 and "/**" not in lines[start]:
            if "*/" in lines[start] and start != end:
                return ""                     # the comment above is no JSDoc
            start -= 1
        if start < 0:
            return ""
        words = []
        for raw in lines[start:end + 1]:
            text = raw.strip()
            text = text.split("/**", 1)[1] if "/**" in text else text
            text = text.rsplit("*/", 1)[0] if text.endswith("*/") else text
            text = text.lstrip("*").strip()
            if text.startswith("@"):
                break                         # a tag ends the description
            if text:
                words.append(text)
            elif words:
                break                         # a blank line ends the first paragraph
        doc = " ".join(words)
        m = re.match(r"(.+?[.!?])(?:\s|$)", doc)
        return m.group(1) if m else doc

    def touches(self, path, name, tables, warn):
        """({table: [via]} read, {table: [via]} written) by a function: its own SQL, and what the functions it calls touch."""
        key = (path, name)
        if key in self.memo:
            return self.memo[key]
        self.memo[key] = ({}, {})             # a call back into a function being read adds nothing
        reads, writes = {}, {}
        body = self.body(path, name)
        for m in STRING.finditer(body):
            literal = NOT_A_TABLE.sub(" ", next(g for g in m.groups() if g is not None))
            sql = SQL_VERB.search(literal)
            if sql is None:
                continue                      # prose, a path, a message: no SQL
            ctes = set(c.group(1) for c in CTE.finditer(literal)) if re.search(r"\bWITH\b", literal, re.I) else set()
            for t in TOUCH.finditer(literal, sql.start()):
                verb, table, call = t.group(1).upper().split()[0], t.group(2), t.group(3)
                if (call and verb in ("FROM", "JOIN")) or table.upper() in ("SET", "SELECT", "ONLY", "LATERAL"):
                    continue                  # a function's result, or no table (an insert's columns follow its table)
                if table in ctes:
                    continue                  # a name a WITH gave a query
                if table not in tables:
                    warn(f"{name} ({path}) names {table}, which no migration makes: passed over")
                    continue
                (reads if verb in ("FROM", "JOIN") else writes).setdefault(table, []).append(name)
        # the functions it calls: those of the files it uses (the scan says which names), and its own file's
        called = [(other, n) for other, names in self.uses.get(path, []) for n in names if other in self.by_path]
        called += [(path, n) for n, _ in self.functions(path) if n != name]
        for other, n in called:
            if any(n == f for f, _ in self.functions(other)) and re.search(r"\b" + re.escape(n) + r"\s*\(", body):
                r, w = self.touches(other, n, tables, warn)
                for into, got in ((reads, r), (writes, w)):
                    for table, via in got.items():
                        into.setdefault(table, []).extend(via)
        result = ({t: sorted(set(v)) for t, v in sorted(reads.items())}, {t: sorted(set(v)) for t, v in sorted(writes.items())})
        self.memo[key] = result
        return result


def in_folder(path, folder):
    return f"/{folder}/" in f"/{path}"


def read_tables(repo):
    """The tables the migrations leave, and for each the migrations that made or changed it, in order."""
    paths = repo.files(MIGRATIONS)
    texts = [repo.read(p) for p in paths]
    tables = sql.tables(texts)
    made_by = {t: [] for t in tables}
    for path, text in zip(paths, texts):
        for m in re.finditer(r"\b(?:CREATE|ALTER)\s+TABLE\s+(?:IF\s+(?:NOT\s+)?EXISTS\s+)?(?:ONLY\s+)?\"?([\w.]+)\"?", text, re.I):
            name = m.group(1)[len("public."):] if m.group(1).startswith("public.") else m.group(1)
            if name in tables and path not in made_by[name]:
                made_by[name].append(path)
    return tables, made_by


def column_text(c):
    return " ".join([c.name, c.type] + (["primary key"] if c.primary_key else ["not null"] if not c.nullable else []))


def events(function):
    """What invokes a Lambda, in words: `POST /webhooks/payment`, `schedule rate(1 day)`, `sqs`."""
    out = []
    for event in function.get("events") or []:
        for kind, value in (event.items() if isinstance(event, dict) else []):
            if kind in ("http", "httpApi") and isinstance(value, dict):
                out.append(f"{str(value.get('method', '*')).upper()} /{str(value.get('path', '')).lstrip('/')}")
            elif isinstance(value, str):
                out.append(f"{kind} {value}")
            else:
                out.append(kind)
    return out


# ---- the digest -----------------------------------------------------------------------------------------------------------

def digest(scan, repo):
    d = Digest(scan.name or repo.name)
    code = Code(scan, repo)
    tables, made_by = read_tables(repo)
    services = [m for m in scan.production if (scan.modules[m].get("path") or "").startswith(SERVICES)]
    for m in scan.production:
        if m not in services and any(in_folder(f["path"], WORKFLOWS) or in_folder(f["path"], ACTIVITIES) for (mm, _), f in sorted(scan.files.items()) if mm == m):
            d.warn(f"{m} ({scan.modules[m].get('path')}) has a {WORKFLOWS}/ or {ACTIVITIES}/ folder but is not under {SERVICES}: it is not drawn")
    module_files = {m: sorted(f["path"] for (mm, _), f in scan.files.items() if mm == m) for m in services}

    # what each service holds: workflows and activities by folder, its worker's task queue
    found = {}
    for m in services:
        paths = module_files[m]
        queues = sorted(set(q for p in paths if WORKER.search(code.text(p)) for q in TASK_QUEUE.findall(code.text(p))))
        found[m] = {
            "queue": queues[0] if len(queues) == 1 else None,
            "workflows": [(p, n, line) for p in paths if in_folder(p, WORKFLOWS) for n, line in code.functions(p)],
            "activities": [(p, n, line) for p in paths if in_folder(p, ACTIVITIES) for n, line in code.functions(p)],
            "lambdas": [],
        }
        if len(queues) > 1:
            d.warn(f"{m} has workers on {len(queues)} task queues ({', '.join(queues)}): its workflows say none")
    # the Lambdas, from each serverless.yml, in the service whose files hold their handlers
    for config in repo.files(SERVERLESS):
        folder = config.rpartition("/")[0]
        try:
            loaded = yaml.load(repo.read(config))
        except yaml.YamlError as e:
            d.warn(f"{config} can't be read ({e}): its Lambdas are left out")
            continue
        if loaded is not None and not isinstance(loaded, dict):
            d.warn(f"{config} is not a mapping at its top level: its Lambdas are left out")
            continue
        functions = (loaded or {}).get("functions") or {}
        if not isinstance(functions, dict):     # `functions: ${file(./functions.yml)}` is a string to this reader
            d.warn(f"{config}: functions is not a mapping here ({str(functions)[:40]}): its Lambdas are left out")
            continue
        for name in sorted(functions, key=str):
            if not isinstance(functions[name] or {}, dict):
                d.warn(f"{config}: {name} is not a mapping here ({str(functions[name])[:40]}): left out")
                continue
            handler = str((functions[name] or {}).get("handler") or "")
            stem, _, export = handler.rpartition(".")
            path = next((p for p in (f"{folder}/{stem}{x}" if folder else f"{stem}{x}" for x in HANDLER_FILES) if p in code.by_path), None)
            if path is None or export not in [n for n, _ in code.functions(path)]:
                d.warn(f"{config}: {name}'s handler {handler} is no exported function of the code: left out")
                continue
            module = code.by_path[path]["module"]
            if module not in found:
                d.warn(f"{config}: {name} is in {module}, which is not a service: left out")
                continue
            line = next(l for n, l in code.functions(path) if n == export)
            found[module]["lambdas"].append((path, export, line, name, handler, events(functions[name])))

    # the root: the services, the tables and the types, as rows in that order
    root = {f: d.frame(d.claim(f"the frame {f}", f), rank=rank) for rank, f in enumerate(ROOT_FRAMES)}
    # the types' titles first: `is` names a type by its title, so each is unique among the types (and only there)
    type_title = {t: d.claim(f"the type {t}", t, within=root[TYPES_FRAME], type=True) for t in list(TYPES) + list(RELATIONSHIPS)}
    card = {}
    for m in services:
        f = found[m]
        said = [f"{len(f[k])} {k if k != 'lambdas' else 'Lambdas'}" for k in ("workflows", "activities", "lambdas") if f[k]]
        text = as_text(f"{m}: " + (", ".join(said) or "nothing found") + (f".\nIts worker runs on the task queue {f['queue']}." if f["queue"] else "."))
        card[m] = d.subboard(d.claim(f"the service {m}", m, most=74, within=root[SERVICES_FRAME]), root[SERVICES_FRAME], text, source=scan.modules[m]["path"])
    table_note = {}
    for t, table in tables.items():
        table_note[t] = d.note(d.claim(f"the table {t}", t, within=root[TABLES_FRAME]), root[TABLES_FRAME], as_text(f"The {t} table, as the migrations leave it."),
                               **({"source": made_by[t][0]} if made_by[t] else {}),
                               **typed("Table", type_title, {"name": t, "columns": [column_text(c) for c in table.columns], "migrations": made_by[t]}))
    type_note = {}
    for t, (words, properties) in TYPES.items():
        type_note[t] = d.note(type_title[t], root[TYPES_FRAME], words, schema=schema(properties))
    for t, (words, properties) in RELATIONSHIPS.items():
        type_note[t] = d.note(type_title[t], root[TYPES_FRAME], words, schema=schema(properties), relationship=True)
    for a, b, row, rule in ENDS:
        d.edge(type_note[a], type_note[b], text=row, **({"endRule": rule} if rule else {}))

    # a service's board: its workflows, activities and Lambdas, each a note of its type in a frame of its own
    note_of = {}                                # (service, "workflows" | "activities" | "lambdas", name): its note
    for m in services:
        f = found[m]
        held = {"Workflows": f["workflows"], "Activities": f["activities"], "Lambdas": f["lambdas"]}
        frame = {}
        for rank, name in enumerate(n for n in SERVICE_FRAMES if held[n]):
            frame[name] = d.frame(d.claim(f"the frame {name} of {m}", name, within=card[m]), card[m], rank=rank)
        for p, n, line in f["workflows"]:
            note_of[(m, "workflows", n)] = d.note(d.claim(f"the workflow {n} of {m}", n, within=frame["Workflows"]), frame["Workflows"],
                                                  as_text(code.doc(p, line)), source={"path": p, "line": line},
                                                  **typed("Workflow", type_title, {"name": n, "file": p, "taskQueue": f["queue"]}))
        for p, n, line in f["activities"]:
            note_of[(m, "activities", n)] = d.note(d.claim(f"the activity {n} of {m}", n, within=frame["Activities"]), frame["Activities"],
                                                   as_text(code.doc(p, line)), source={"path": p, "line": line},
                                                   **typed("Activity", type_title, {"name": n, "file": p}))
        for p, export, line, name, handler, said in f["lambdas"]:
            note_of[(m, "lambdas", name)] = d.note(d.claim(f"the Lambda {name} of {m}", name, within=frame["Lambdas"]), frame["Lambdas"],
                                                   as_text(code.doc(p, line)), source={"path": p, "line": line},
                                                   **typed("Lambda", type_title, {"name": name, "handler": handler, "events": said}))

    # the relationships: a workflow runs the activities it calls, in the order it first calls them; an activity or a Lambda
    # reads and writes the tables its SQL, and its callees', touch
    for m in services:
        f = found[m]
        activity = {n: note_of[(m, "activities", n)] for _, n, _ in f["activities"]}
        ran = {}                                # a workflow file's path: how many activities its workflows run
        for p, n, _ in f["workflows"]:
            text = code.text(p)
            proxied = {}                        # `const { a, b: c } = proxyActivities()`: the name a call uses -> the activity
            for block in PROXY.findall(text):
                for part in block.split(","):
                    name, _, local = (x.strip() for x in part.partition(":"))
                    if name:
                        proxied[local or name] = name
            body = code.body(p, n)
            found_calls = [(m2.start(), name) for local, name in proxied.items()
                           for m2 in [re.search(r"\b" + re.escape(local) + r"\s*\(", body)] if m2]
            for space in PROXY_NAMESPACE.findall(text):     # `const acts = proxyActivities()`, called as `acts.a()`
                found_calls += [(m2.start(), m2.group(1)) for m2 in re.finditer(r"(?<![\w$.])" + re.escape(space) + r"\.([A-Za-z_$][\w$]*)\s*\(", body)]
            step = 0
            seen = set()
            for _, name in sorted(found_calls):
                if name in seen:
                    continue
                seen.add(name)
                if name not in activity:
                    d.warn(f"{n} ({p}) runs {name}, which is no activity of {m}: passed over")
                    continue
                step += 1
                d.edge(note_of[(m, "workflows", n)], activity[name], direct=RUNS_DIRECT, **{"is": type_title["runs"], "fieldValues": {"step": step}})
            ran[p] = ran.get(p, 0) + step
        for p in sorted(ran):
            if not ran[p] and PROXY_MENTION.search(code.text(p)):
                d.warn(f"{p} mentions proxyActivities and none of its workflows runs an activity of {m}: a form this lens doesn't read, or no calls")
        callers = [(note_of[(m, "activities", n)], p, n) for p, n, _ in f["activities"]]
        callers += [(note_of[(m, "lambdas", name)], p, export) for p, export, _, name, _, _ in f["lambdas"]]
        for note, p, n in callers:
            reads, writes = code.touches(p, n, tables, d.warn)
            for how, touched in (("reads", reads), ("writes", writes)):
                for t, via in touched.items():
                    d.edge(note, table_note[t], **{"is": type_title[how], "fieldValues": {"via": via}})
    return d.finish()


def typed(kind, type_title, values):
    """A note's `is` and its values, the empty ones left out."""
    return {"is": type_title[kind], "fieldValues": {k: v for k, v in values.items() if v not in (None, "", [])}}
