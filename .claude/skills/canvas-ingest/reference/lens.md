# Writing a lens

A lens is the repository's own picture of its code: `.canvas/lens.py`, a function `digest(scan, repo)` that returns the digest canvas-digest draws ([its format](../../canvas-digest/reference/graph.md)). `ingest` reads it from the folder you run in, never from the commit drawn, so an edit counts at once, committed or not. It runs it twice, isolated, and refuses it when the two digests differ ([Determinism](#determinism-and-the-runner)). Without a lens, `ingest` draws with the default lens.

A lens imports `lenskit`, which is in the skill's folder (`ingest` puts it on the path), and anything in the folder beside `lens.py`. [The orders example](../examples/orders/.canvas/lens.py) is a whole lens built on it.

## Contents

- [Two ways to start](#two-ways-to-start)
- [The scan](#the-scan)
- [repo, the code at the commit](#repo-the-code-at-the-commit)
- [The digest builder](#the-digest-builder)
- [The texts](#the-texts)
- [The default lens and its arguments](#the-default-lens-and-its-arguments)
- [Reading YAML](#reading-yaml)
- [Reading SQL migrations](#reading-sql-migrations)
- [Types in a digest](#types-in-a-digest)
- [Named rules](#named-rules)
- [What a lens's conventions miss](#what-a-lenss-conventions-miss)
- [Determinism and the runner](#determinism-and-the-runner)
- [Python 3.9](#python-39)
- [A short lens](#a-short-lens)

## Two ways to start

- **The default lens, with arguments.** For a repository whose picture is its modules: modules as cards in bands, a module's files as notes in frames, imports and uses as arrows.

  ```python
  from lenskit import default

  def digest(scan, repo):
      return default.digest(scan, repo, bands=[("Apps", ["web", "api"]), ("Libraries", ["core"])])
  ```

- **A lens of its own**, built with `lenskit.Digest`. For a repository whose picture is its things: services, workflows, Lambdas, tables. Find each by the repository's convention through `repo` and the scan, make the kinds types, and connect them with relationships. The orders example is one.

## The scan

`scan` is a `lenskit.Scan`, the scan the scanner wrote ([its format](scan.md#scanjson)), with lookups:

| member | what it is |
|---|---|
| `scan.language` | `"swift"`, `"typescript"`, ...: the words a note uses |
| `scan.name` | what the code calls itself (a Swift package's name, else the repository's), or None |
| `scan.modules` | `{name: module}`, test modules too. A module is a dict: `name`, `path` (its folder), `deps` (the drawn modules it imports), `test`, `layer`, `files`, `lines`, `doc`, `folders` (`{folder: doc}`) |
| `scan.production` | the names of the drawn modules (not tests), in the scan's order |
| `scan.files` | `{(module, rel): file}`, production modules' files only. A file is a dict: `module`, `rel` (its path in its module), `path` (in the repository), `lines`, `doc`, `api`, `decls` |
| a file's `decls` | `[{name, kind, visibility, line}]`: its top-level declarations. `kind` is `type`, `function`, `extension`, `value` or `other`; `visibility` `public`, `internal` or `private`; `line` from 1 |
| `scan.uses` | `[(from, to, names)]`: file `from` uses file `to` (each a `(module, rel)`), once a pair, with the names it uses (`["*"]` for a whole file: `export *`, a namespace import). Test modules' uses are in it too: keep those whose ends are in `scan.files` |
| `scan.module(name)`, `scan.file(module, rel)` | one of each |
| `Scan.load(path)` | a scan from a file, for trying a lens by hand |

A declaration's `line` is where it starts, so a function's body is the lines from its line to the next declaration's (the orders lens's `Code.body`). Which file uses which comes from the compiler's index, so it follows imports across packages and through re-exports: a call from a service into a db package lands on the file that defines the function. That holds where the indexer resolves the packages: one whose `package.json` points at built files nothing built resolves to nothing ([scan.md](scan.md#workspaces-that-resolve-through-built-files); the scan says so).

## repo, the code at the commit

`repo` is a `lenskit.Repo`: the commit being drawn, read through git, never the working tree.

| member | what it is |
|---|---|
| `repo.files(pattern=None)` | the commit's paths, sorted, matching a glob over the whole path: `*` and `?` stay in one folder's name, `**/` crosses folders and may match none (`**/*.sql` takes `a.sql`), `[abc]` one of those. No pattern is every path. No `.gitignore` rules |
| `repo.read(path)` | the file as text (UTF-8, U+FFFD where it isn't). `FileNotFoundError` for a path the commit lacks |
| `repo.read_bytes(path)`, `repo.exists(path)` | its bytes; whether the commit has it |
| `repo.commit` | the commit's sha |
| `repo.name` | the name of the folder `ingest` runs in. A worktree's differs from the main checkout's, so title nothing with it: `scan.name` is the repository's |

A submodule is no file: its folder is empty. Never `open()` a file of the repository: that reads the working tree, not the commit, and makes a board that changes with uncommitted edits.

## The digest builder

`lenskit.Digest` builds the digest by title and gives every title out once.

```python
from lenskit import Digest

d = Digest("shop")
d.frame("Services", rank=0)
d.subboard("@shop/orders", "Services", "What the service runs.", source="services/orders/src")
d.note("orders", "Database", "The orders table.", source="db/migrations/002_orders.sql")
d.edge("createOrder", "orders", weight=2)
return d.finish()
```

| member | what it does |
|---|---|
| `Digest(title)` | the digest's title, what the whole is called; it can be set later: `d.title`. No board has a note of what it is: a subboard's `text` is its card's description |
| `d.claim(what, wanted, *others, most=80)` | a title no other shape has: `wanted`, else each of `others`, else the last with a number after it, cut to `most` characters (keeping its end behind an ellipsis). Two titles that differ only in case or spaces are one title. A title that gives way is said as a warning naming `what`. Claim the titles queries name first (tables, types), then the rest. A name many places share (an `example` workflow in every sample) goes bare to whichever claims it first: claim such names qualified from the start (`f"{name} ({sample})"`), so no one of them is the bare name by the order of a loop |
| `d.add(title, kind, parent=None, text=None, **extra)` | a node: `kind` `sticky-note`, `frame`, `subboard` or `auto`; `parent` the frame or subboard it is in; `extra` goes into the node as it is. Returns the node (a dict you may still change) |
| `d.frame(title, parent=None, **extra)`, `d.subboard(...)`, `d.note(...)` | `add` for each kind; `subboard` and `note` take `text` third (a note's words; a subboard's is its description, which may mention shapes as `@[Title]` and is shown in the card's panel, never on the canvas) |
| `d.edge(source, target, weight=None, **extra)` | an edge between two titles (notes or subboards, never frames) |
| `d.warn(message)` | a warning, said by `ingest` as `lens: <message>`; never stops the run |
| `d.finish()` | the digest: `{title, nodes, edges, warnings}` |

The fields a node or an edge can carry are in [graph.md](../../canvas-digest/reference/graph.md): on a node `rank` (rows or columns in its container), `public`, `source`, `schema`, `relationship`, `is`, `fieldValues`; on an edge `text`, `weight`, `direct` (never a pill), `via: "reference"` (always a pill), `is`, `fieldValues`, `endRule`. `is` is a word Python keeps, so pass it in a dict: `d.note("orders", "Database", **{"is": "Table"})`.

Give every node a `source`: the path it was made from, or `{"path": ..., "line": ...}`. The drawing ignores it, and it is how a shape the user points at is mapped back to the code.

A digest's limits are canvas-digest's: titles at most 80 characters and unique in the file, about 15 shapes a frame, about 150 a board. `ingest` runs `digest check`, which warns past them. One `canvas query` lists at most 10,000 titles, so keep a digest well under that.

## The texts

`lenskit.text`, for what a note says:

- `as_text(s)`: text shown as written. `@[` starts a mention in `canvas draw`, so wrap every text the code gave you (a doc, a name) in it.
- `mention(title)`: a mention of the shape with that title, `@[title]`, escaped as draw reads one.
- `file_text(file, language)`: a file's note as the default lens writes it: its doc, what it declares, its length. `declares(file, most=60)`: what it declares, in a few words. `words(language)`: the words those use (TypeScript says `exports`, Swift `public`). `names(xs, cap=10)`: a list cut to `cap`, with `+N`.

## The default lens and its arguments

`lenskit.default.digest(scan, repo=None, **arguments)` draws modules as cards in bands on the root, a module's board with its files as notes in frames by folder, a module's imports and a file's uses as arrows (weighted by the names used, up to 4), and a use of a file on another board as a pill. Each argument replaces what it would work out; what it leaves out is still worked out, and what it names that the code lacks is passed over and warned.

| argument | value | without it |
|---|---|---|
| `title` | `str` | `scan.name`, else the repository's folder |
| `bands` | `[(title, [module])]`, top to bottom | by the modules' `layer` tags when every module has one, else by how deep each module's imports go. A module left out goes in its layer's band, else "Other modules" |
| `purposes` | `{module: text}` | what the scanner found: a README's first sentence, a module's doc |
| `folder_purposes` | `{"<module>/<folder>": text}` | the same, for a folder's board |
| `folder_boards` | `{module: [folder]}`: folders with boards of their own | each top folder of a module of over 50 files, when it has two or more |
| `groups` | `{board: [(title, [file], [subgroup])]}`: a board's frames, files by their path in the board's folder | frames by folder, two deep. A file left out goes in a frame `<board>/` |
| `by_module` | `[(module, file)]`: files whose arrows point at modules, not files | none |
| `layer_names` | `{tag: name}` | the tags as written |

Any other keyword is a `TypeError` listing these. Past 4,000 file notes it draws a folder's files as one note, the deepest folders first, and warns how many. The default lens's digest is a dict like any other: a lens can call it and change the result, but a title it adds must be one the digest doesn't have (`digest check` refuses a duplicate).

## Reading YAML

`lenskit.yaml.load(text)` reads a config file into dicts, lists, strings, integers, floats, booleans and None:

```python
from lenskit import yaml
config = yaml.load(repo.read("services/billing/serverless.yml"))
functions = config.get("functions") if isinstance(config, dict) else None
if not isinstance(functions, dict):
    d.warn("services/billing/serverless.yml: no functions mapping here: its Lambdas are left out")
    functions = {}
```

**It reads:**

- block mappings and sequences (a sequence may sit at its key's indent);
- plain scalars: `null`, `~`, `true` and `false`, integers and floats; anything else is text, so `yes` and `on` are text, as in YAML 1.2, and `${file(./x.yml)}` is a string;
- 'single' and "double" quoted strings with their escapes (one that is no character, `"\U00110000"`, is an error);
- comments, and a byte order mark at the start;
- literal and folded block scalars, `|` and `>` (`-` strips the last line break, `+` keeps the blank lines after the text, else one line break ends it);
- one-line flow collections, `[a, b]` and `{a: b}`, nested.

**It refuses**, with a `yaml.YamlError` naming the line: anchors and aliases (`&`, `*`, the `<<` merge key), tags (`!Ref`, so most CloudFormation), a second document (`---` again, `...`), `? ` complex keys, a tab in the indentation, a flow collection over several lines, a plain scalar over several lines, and a key given twice. Catch the error and warn: a config the reader can't take shouldn't stop the drawing.

**It gives a string, a list or None where you expected a mapping** when the file says so (`functions: ${file(./functions.yml)}`, an empty file, a list at the top): check `isinstance(x, dict)` before `.get` or `sorted`, and warn naming the file, as the orders lens does.

## Reading SQL migrations

`lenskit.sql.tables(texts)` reads migrations, in order, into `{name: Table}`:

```python
from lenskit import sql
paths = repo.files("db/migrations/*.sql")                # sorted, so 001_ before 002_
tables = sql.tables([repo.read(p) for p in paths])
tables["orders"].columns                                 # [Column(name, type, nullable, primary_key)]
```

A `Table` has `name`, `schema` (`app` in `app.users`; `public.` is no schema), `key` (`schema.name`, or the name), `columns` and `column(name)`. A `Column` has `name`, `type` (`character varying(255)`, `timestamp with time zone`, `text[]`), `nullable` and `primary_key`.

**It reads**, in order:

- `CREATE TABLE [IF NOT EXISTS] name (...)`: each column's name and type, whether it may be null (`NOT NULL` and `PRIMARY KEY` on the column say not) and whether it is a primary key (on the column, or in a table-level `PRIMARY KEY (a, b)`).
- `ALTER TABLE name` with `ADD [COLUMN] [IF NOT EXISTS] col type ...`, `DROP COLUMN`, `RENAME COLUMN a TO b`, `RENAME TO new`, `ADD PRIMARY KEY (a)`, `ALTER COLUMN a SET NOT NULL`, `ALTER COLUMN a DROP NOT NULL`, `ALTER COLUMN a TYPE t` (also `SET DATA TYPE t`, and T-SQL's `ALTER COLUMN a t [NOT NULL]`), and MySQL's `MODIFY a t ...` and `CHANGE a b t ...` (a column keeps its place, and its primary key; `AFTER x` and `FIRST` are no part of a type).
- `DROP TABLE [IF EXISTS] a, b`.
- A name as written without its quotes (`"x"`, `` `x` ``), a schema before it kept (`app.users`) but for `public.`, and any letters in it (`größe`).

**It skips, without a word:** every other statement (indexes, inserts, views, functions, comments, grants); a `CREATE TABLE ... AS SELECT` or `... PARTITION OF` (no columns are written); a temporary table (`CREATE TEMP TABLE`); a table-level constraint but the primary key (a unique key, a foreign key, `CHECK`, `EXCLUDE`); an ALTER of a table no migration made; comments and `$$ ... $$` bodies (taken out in the pass that reads the strings, so a `'--'` or `'/*'` in a default is a string). A column is not null only by `NOT NULL` or `PRIMARY KEY` written on it, never by a `CHECK (x IS NOT NULL)`. A word that can start a table-level constraint (`KEY`, `INDEX`, `EXCLUDE`, `PERIOD`, `FULLTEXT`, `SPATIAL`, `LIKE`) is a column's name when a type follows (`key text PRIMARY KEY`).

**It does not read:** `[x]` identifiers (T-SQL), nested block comments, and a type it has never heard of after such a word (that reads as a constraint). For a schema kept in an ORM (Prisma's `schema.prisma`, TypeORM's `@Entity`), read the files with `repo` and a regular expression of your own. Migrations written in code (MikroORM's `this.addSql(...)`, TypeORM's `queryRunner.query(...)`, Knex's `raw`) give `tables` nothing as they are: pull the SQL out of their strings first, which misses a statement built from pieces, or read what the ORM keeps of the schema itself, exact and whole (MikroORM's `migrations/.snapshot-*.json`, a table each with its columns: Medusa's 26 modules, 136 tables).

## Types in a digest

A digest can say what its things are, so a question about them is a `canvas query`. The format, what `check` refuses and the order things are drawn in are canvas-digest's: [graph.md, Types](../../canvas-digest/reference/graph.md#types). What a lens writes:

```python
TABLE = {"type": "object", "properties": {"name": {"type": "string"}, "columns": {"type": "array", "items": {"type": "string"}}}, "required": ["name"]}
WRITES = {"type": "object", "properties": {"via": {"type": "array", "items": {"type": "string"}}}}

d.frame("Types", rank=2)
d.note("Table", "Types", "A Postgres table: its name and its columns.", schema=TABLE)              # a type
d.note("Activity", "Types", "A Temporal activity: its name.", schema=ACTIVITY)
d.note("writes", "Types", "An activity writes a table.", schema=WRITES, relationship=True)        # a relationship type
d.edge("Activity", "writes", text="writes")                                                     # its from end: the row an Activity gets
d.edge("writes", "Table", text="written by", endRule={"needed": True})                          # its to end: every Table needs a writer
d.note("orders", "Database", "The orders table.", **{"is": "Table", "fieldValues": {"name": "orders", "columns": ["id text primary key"]}})
d.edge("createOrder", "orders", **{"is": "writes", "fieldValues": {"via": ["insertOrder"]}})     # a relationship
```

- A type's `text` and its `schema` say the same thing, in words and as JSON Schema. Its title is its name: no `"title"` in the schema.
- A relationship type and the types at its ends are on one board (a frame on the root is the usual place). Notes of a type can be on any board; a relationship to a note on another board is drawn into a pill, and the note is made public.
- Values are held to the schema's `type`, `properties`, `required`, `enum` and `items`. Leave an empty value out (None counts as none). Lists of strings read well in a note's row.
- `endRule` `{"needed": true}` makes every note at that end need such a relationship, and one without is `:incomplete`, said by the drawing as a warning by design. Use it for what the team wants found (an activity no workflow runs).
- Title the types as people say them, and keep the titles of the things queries name (tables, workflows) as the code says them: claim those first.

Then: `canvas query ':is-a("Table")'` lists the tables, `arrow:is-a("writes")` the writes, `:start-of(arrow:is-a("writes"):ends-at("orders"))` who writes orders, and `:start-of(arrow:is-a("runs"):ends-at(:start-of(arrow:is-a("writes"):ends-at("orders"))))` the workflows that run them ([the canvas skill's query reference](../../canvas/reference/query.md)).

## Named rules

Every decision in a lens is a rule with a name and a reason, so a later round doesn't undo an earlier one. A rule is a comment and the code it governs:

```python
# Rule "workflows-on-top": a service's board has a frame each for its workflows, activities and Lambdas, top to bottom.
# Why: a service is read from what starts work down to what does it (round 1).
SERVICE_FRAMES = ("Workflows", "Activities", "Lambdas")

# Rule "runs-are-arrows": a workflow's arrows to its activities are never pills. Why: a workflow's steps read as a flow
# only when the lines are there (round 2: the first drawing showed checkout's three steps as pills).
RUNS_DIRECT = True
```

- **One request, one rule.** Name it for what it does (`tables-on-the-root`), never for when it came (`fix-2`).
- **Say why, and where it came from**: the user's reason in their words, and the round.
- **The code names the rule's constant**, so a reader goes from the rule to the code and back. Keep the rules together at the top of the lens, in the order they apply.
- **Make it general.** A user who points at one shape is showing a case of something: write the rule for the case ("activities with no workflow go last"), never for the shape.
- **Read the rules before changing the lens.** A request that goes against a rule: name the rule and its reason to the user, and ask which wins. Then change that rule's text and code, and its round. Never add a rule that undoes another.
- **Art direction is often a field.** Order is `rank` on frames or nodes; a part to open is a `subboard`, a group to see at a glance a `frame`; a line that must stay a line is `direct: True`, one that must be a pill `via: "reference"`; a hub kept off pills is `public: False`. Tidiness as a whole is the `mess` setting, and which way the root's bands run the `ranks` setting, not rules.

## What a lens's conventions miss

A lens finds things by the conventions you listed, so a thing built another way is not drawn, and a lens can warn only of what it can see. The orders example says what its own conventions miss ([its README](../examples/orders/README.md#what-the-lens-does-not-read)), and a lens for a real repository should do the same for its own. In that lens:

- A function's reads and writes follow **exported functions** only. A private helper that holds the SQL, a query builder, an ORM or a class-based data layer gives no reads or writes, and nothing is said.
- Workflows run activities through `const { a } = proxyActivities(...)` or `const acts = proxyActivities(...)` and `acts.a()`, by name or through a namespace (`wf.proxyActivities`). Another form (a proxy made in a helper) is warned when the file mentions `proxyActivities` and no activity was matched in it. An activity passed as a value (`execute: getWeather`), called from a private helper or a class's method, a class-based workflow, and a worker that loads a prebuilt `workflowBundle` give nothing, and nothing is said.
- Every exported function in an `activities/` folder is an activity. An exported helper no workflow runs is `:incomplete`, by the rule "every-activity-is-run".
- A service is a module under `services/`; one elsewhere that has `workflows/` or `activities/` folders is warned.
- A `serverless.yml` whose `functions` is not written in the file (`${file(...)}`) is warned and its Lambdas are left out.

Turn what a lens can see into a warning (`d.warn`), and what it cannot into a line in the lens's README or docstring.

## Determinism and the runner

The same commit, lens, app and macOS must draw the same boards, so `ingest` runs the lens twice, at once, each isolated (`runner/run.py`): `env -i` with only `PATH=/usr/bin:/bin`, a `HOME` that is an empty folder (a different one each run), `TZ=UTC`, `LC_ALL=C`, `PYTHONHASHSEED` 1 in one run and 2 in the other, a fresh empty folder as the current folder, and a clock that reads 2001 in one run and 2020 in the other. It writes each digest as JSON in the lens's own order and compares them byte for byte. A difference is refused, naming the first node or edge that differs and its usual causes; nothing is drawn. A lens that raises stops the run with its traceback. One over 900 seconds is stopped.

What keeps a lens deterministic:

- Read the code only through `repo`, never `open()` or the working tree.
- Sort: iterate a set, a dict built from one, or a folder's listing only sorted. A dict keeps the order you put things in, so build it in a sorted order.
- No clock: no `time.time`, `datetime.now`, `date.today`.
- No environment: no `os.environ`, `HOME`, the current folder, the user or the host.
- No network and no randomness: no `random`, `uuid`, sockets.

The runner catches what changes between its two runs. It can't catch a file read outside `repo` that happens not to change.

## Python 3.9

The lens runs under `/usr/bin/python3`, which is 3.9, with the standard library and lenskit and nothing installed (`-s`: not even the user's packages). So: no `match`; no `X | Y` in an annotation Python evaluates (write `Optional[X]`, or start the file with `from __future__ import annotations`); no `tomllib`, `zip(strict=True)`, `itertools.pairwise` or `dataclass(slots=True)`. `str.removeprefix`, dict union `|` and `list[int]` in annotations are there.

## A short lens

A repository whose services are in `docker-compose.yml`: each service a note of the type Service, with its image, and an arrow for each `depends_on`.

```python
"""The services docker-compose.yml runs, and which needs which."""
from lenskit import Digest, yaml
from lenskit.text import as_text

# Rule "services-from-compose": a service is one docker-compose.yml runs. Why: compose is what runs locally (round 1).
COMPOSE = "docker-compose.yml"

SERVICE = {"type": "object", "properties": {"name": {"type": "string"}, "image": {"type": "string"}}, "required": ["name"]}
NEEDS = {"type": "object", "properties": {}}


def digest(scan, repo):
    d = Digest(scan.name or "Services")
    services = (yaml.load(repo.read(COMPOSE)) or {}).get("services") or {}
    title = {name: d.claim(f"the service {name}", name, f"{name} (service)") for name in sorted(services)}
    d.frame("Types", rank=1)
    d.note("Service", "Types", "A service compose runs: its name and image.", schema=SERVICE)
    d.note("needs", "Types", "A service needs another to start.", schema=NEEDS, relationship=True)
    d.edge("Service", "needs", text="needs")
    d.edge("needs", "Service", text="needed by")
    d.frame("Running", rank=0)
    for name in sorted(services):
        values = {"name": name, "image": (services[name] or {}).get("image")}
        d.note(title[name], "Running", as_text(f"{name}"), source=COMPOSE,
               **{"is": "Service", "fieldValues": {k: v for k, v in values.items() if v}})
    for name in sorted(services):
        for other in sorted((services[name] or {}).get("depends_on") or []):
            if other in title:
                d.edge(title[name], title[other], **{"is": "needs"})
    return d.finish()
```
