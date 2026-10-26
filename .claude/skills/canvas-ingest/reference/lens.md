# Writing a lens

A lens is the repository's own picture of its code: `.canvas/lens.py`, a function `digest(scan, repo)` that returns the digest canvas-digest draws ([its format](../../canvas-digest/reference/graph.md)). `ingest` reads it from the folder you run in, never from the commit drawn, so an edit counts at once, committed or not. It runs it twice, isolated, and refuses it when the two digests differ ([Determinism](#determinism-and-the-runner)). Without a lens, `ingest` draws with the default lens.

A lens imports `lenskit`, which is in the skill's folder (`ingest` puts it on the path), and anything in the folder beside `lens.py`. [The bookshelf example](../examples/bookshelf/.canvas/lens.py) and [the orders example](../examples/orders/.canvas/lens.py) are whole lenses built on it.

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
- [Files as a type](#files-as-a-type)
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

  Its files are plain notes. Usually they are notes of the type File: `default.build` with the same arguments, and its file notes typed before it is finished ([Files as a type](#files-as-a-type)). The bookshelf example is one.

- **A lens of its own**, built with `lenskit.Digest`. For a repository whose picture is its things: services, workflows, Lambdas, tables, and usually the files they are declared in. Find each by the repository's convention through `repo` and the scan, make the kinds types, and connect them with relationships. The orders example is one.

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

`lenskit.Digest` builds the digest from nodes, and gives every title out once in the container that holds the shape.

```python
from lenskit import Digest

d = Digest("shop")
services = d.frame("Services", rank=0)
database = d.frame("Database", rank=1)
orders = d.subboard("@shop/orders", services, "What the service runs.", source="services/orders/src")
table = d.note(d.claim("the orders table", "orders", within=database), database, "The orders table.", source="db/migrations/002_orders.sql")
create = d.note(d.claim("createOrder", "createOrder", within=orders), orders, "Makes an order.", source="services/orders/src/create.ts")
d.edge(create, table, weight=2)
return d.finish()
```

A shape is named by the node `add`, `frame`, `subboard` or `note` returned for it: `parent` and an edge's ends take a node (or a title, where one node has it). Titles are unique **in a container** (the nodes with the same `in`; the top of the first board is one), not in the whole digest: a folder's `index.ts` and another's are two notes of one name, as the app tells shapes apart by their containers.

| member | what it does |
|---|---|
| `Digest(title)` | the digest's title, what the whole is called; it can be set later: `d.title`. No board has a note of what it is: a subboard's `text` is its card's description |
| `d.claim(what, wanted, *others, within=None, most=80, alone=False, type=False)` | a title no other shape in the container has: `wanted`, else each of `others`, else the last with a number after it, cut to `most` characters (keeping its end behind an ellipsis). Two titles that differ only in case or spaces are one title. A title that gives way is said as a warning naming `what`. Claim the shapes that matter most first (the titles queries name: tables, types), then the rest, container by container. A name many shapes of one container share (an `example` workflow in every sample, all in one frame) goes bare to whichever claims it first: claim such names qualified from the start (`f"{name} ({sample})"`), so none of them is the bare name by the order of a loop; names in different containers need no qualifying. `within` is the node that will hold the shape (what `add` returned; or its title, where one node has it, else a `ValueError`) and `None` the top of the first board: a lens that passes none claims everything in one scope, so every title in it is given out once in the whole digest. `alone=True` makes the title the digest's alone, whichever container a shape is in, for a shape a text mentions (`@[Title]` names a shape by its title alone). `type=True` makes it unique among the types (notes with a `schema`) of the digest: `is` names a type by its title |
| `d.add(title, kind, parent=None, text=None, **extra)` | a node: `kind` `sticky-note`, `frame`, `subboard` or `auto`; `parent` the frame or subboard it is in, as the node `add` returned for it, or its title; `extra` goes into the node as it is. Returns the node (a dict you may still change: its title, its `in`) |
| `d.frame(title, parent=None, **extra)`, `d.subboard(...)`, `d.note(...)` | `add` for each kind; `subboard` and `note` take `text` third (a note's words; a subboard's is its description, which may mention shapes as `@[Title]` and is shown in the card's panel, never on the canvas) |
| `d.edge(source, target, weight=None, **extra)` | an edge between two nodes (notes or subboards, never frames), each a node or a title |
| `d.warn(message)` | a warning, said by `ingest` as `lens: <message>`; never stops the run |
| `d.finish()` | the digest: `{title, nodes, edges, warnings}`, with the ids and references below settled |

**A string names a node by its title, or by an id** the lens gave: `d.edge("createOrder", "orders")`. A title that several nodes have names none of them (`check` would refuse it), so `finish()` raises a `ValueError` for it, naming the edge or node: pass the node itself.

**Ids.** `finish()` gives every node whose title another node has (spaces folded, case kept, as the digest matches a title; or whose title is another node's `id`, which a string names first) an `id`, unless the lens gave it one, and writes every `in`, `from` and `to` that names such a node as its id. Every other reference stays the title, so a digest whose titles are all unique comes out as it was written, with no ids. An id is the title, two spaces, `in`, then the titles of the containers the node is in, outermost first, joined by ` > `: `index.ts  in Web layer > web > src`, or `index.ts  in the first board` for a node at the top. That is the digest's own way of telling such nodes apart (the key it makes of a node that has no id), so ids sort as titles do and a row the digest orders by key stays in title order; it is the same at every run, whatever the hash seed, since it is made of titles alone. A number follows an id that another has already (two nodes of one title in one container, which `check` refuses). An id says where the node was when `finish()` ran: a lens that moves nodes should change them, then call `finish()` (below, `default.build`). Two types of one title are refused by `finish()` too: claim a type's title with `type=True`.

The fields a node or an edge can carry are in [graph.md](../../canvas-digest/reference/graph.md): on a node `rank` (rows or columns in its container), `public`, `source`, `schema`, `relationship`, `is`, `fieldValues`; on an edge `text`, `weight`, `direct` (never a pill), `via: "reference"` (always a pill), `is`, `fieldValues`, `endRule`. `is` is a word Python keeps, so pass it in a dict: `d.note("orders", "Database", **{"is": "Table"})`.

Give every node a `source`: the path it was made from, or `{"path": ..., "line": ...}`. The drawing ignores it, and it is how a shape the user points at is mapped back to the code: where several nodes have the title the user's selection names, the row's `inside` (the shape's containers) and the node's `id` tell them apart.

A digest's limits are canvas-digest's: titles at most 80 characters and unique in their container (a type's in the whole digest), about 15 shapes a frame, about 150 a board. `ingest` runs `digest check`, which warns past them. One `canvas query` lists at most 10,000 titles, so keep a digest well under that.

## The texts

`lenskit.text`, for what a note says:

- `as_text(s)`: text shown as written. `@[` starts a mention in `canvas draw`, so wrap every text the code gave you (a doc, a name) in it.
- `mention(title)`: a mention of the shape with that title, `@[title]`, escaped as draw reads one.
- `file_text(file, language, length=True)`: a file's note as the default lens writes it: its doc, what it declares, its length (`length=False` leaves the length out, for a File that holds it as a value: [Files as a type](#files-as-a-type)). `declares(file, most=60)`: what it declares, in a few words. `words(language)`: the words those use (TypeScript says `exports`, Swift `public`). `names(xs, cap=10)`: a list cut to `cap`, with `+N`.

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

Any other keyword is a `TypeError` listing these. Past 4,000 file notes it draws a folder's files as one note, the deepest folders first, and warns how many.

**What it titles things.** A title is given out once in the container that holds the shape ([the digest builder](#the-digest-builder)), so the boards of a codebase repeat names the way its folders do:

- A file's note is titled by its file name. Where another note of the same frame (or of the board's card) has that name, it takes the shortest end of its path that tells it apart there (`Select/index.ts`), then its module's name and its own (`web/index.ts`), then its whole path. A name two frames or boards share is the bare name in each, and the digest tells the notes apart by their ids.
- A frame is titled by its folder's name (the board's own files, in `<board>/`); a frame whose name a note of its container has is `src (Core)`, after its board.
- A band is titled as it is given; a module's card is titled by its module's name, and a folder's card `<module>/<folder>`. A card's title is **the digest's alone**: a folder's card mentions its module's card and the folders it uses as `@[Title]`, which names a shape by its title alone, so nothing else is titled so (a band called what a module is gives way, `Level 1 (layer)`, and so does a frame or a note).
- A collapsed folder's note is titled for the folder, `Module/folder/`.

The default lens's digest is a dict like any other, but its references are names already, and an id says where a node was when the digest was finished. To change the digest (move a card into a frame of the lens's own, say) use `lenskit.default.build(scan, repo, **arguments)`, which returns the `Digest` before `finish()`: its nodes name each other by node, so a lens sets `card['in'] = frame`, adds the frame to `d.nodes`, and calls `d.finish()` itself.

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
d.note("Local activity", "Types", "An activity run in the workflow's worker: its timeout.", schema=LOCAL, **{"is": "Activity"})   # a type built on another
d.note("writes", "Types", "An activity writes a table.", schema=WRITES, relationship=True)        # a relationship type
d.edge("Activity", "writes", text="writes")                                                     # its from end: the row an Activity gets
d.edge("writes", "Table", text="written by", endRule={"needed": True})                          # its to end: every Table needs a writer
d.note("orders", "Database", "The orders table.", **{"is": "Table", "fieldValues": {"name": "orders", "columns": ["id text primary key"]}})
d.edge("createOrder", "orders", **{"is": "writes", "fieldValues": {"via": ["insertOrder"]}})     # a relationship
```

- A type's `text` and its `schema` say the same thing, in words and as JSON Schema. Its title is its name: no `"title"` in the schema.
- A type with `is` builds on those types (a relationship type on relationship types): its notes have their fields too, with its own, and its schema holds only what it adds or restates. A note of Local activity is an Activity, so `:is-a("Activity")` finds it, an end at Activity gives it its row, and a relationship whose end is an Activity fits it. What a type builds on may be on any board.
- A relationship type and the types at its ends are on one board (a frame on the root is the usual place). Notes of a type can be on any board; a relationship to a note on another board is drawn into a pill, and the note is made public.
- Values are held to the schema's `type`, `properties`, `required`, `enum` and `items`. Leave an empty value out (None counts as none). Lists of strings read well in a note's row.
- `endRule` `{"needed": true}` makes every note at that end need such a relationship, and one without is `:incomplete`, said by the drawing as a warning by design. Use it for what the team wants found (an activity no workflow runs).
- Title the types as people say them, and keep the titles of the things queries name (tables, workflows) as the code says them: claim those first. Claim a type's title with `type=True`: it is given out once among the digest's types, in whichever frame each is, and a note that is no type may have it too (a table called `Table`). `finish()` refuses two types of one title, since `is` names a type by its title.

Then: `canvas query ':is-a("Table")'` lists the tables, `arrow:is-a("writes")` the writes, `:start-of(arrow:is-a("writes"):ends-at("orders"))` who writes orders, and `:start-of(arrow:is-a("runs"):ends-at(:start-of(arrow:is-a("writes"):ends-at("orders"))))` the workflows that run them ([the canvas skill's query reference](../../canvas/reference/query.md)).

## Files as a type

Most repositories draw their files as notes of a type File, and setup recommends it ([SKILL.md](../SKILL.md), round one): `:is-a("File")` lists them, a file's panel shows it as one, and its values answer queries (`:is-a("File")[fieldValues.lines>500]`, `:is-a("File")[fieldValues.path^="src/api/"]`). The default lens draws files as plain notes; a lens types them.

**Few fields.** Each is a row on every file's note, so each makes every note taller. `path` and `lines` are the usual two, and the note's words are its doc and what it declares, `file_text(f, language, length=False)`, which leaves out the length the note now holds as a value. Leave File no color of its own (no `$color`), so files stay the notes' yellow and the types that have one stand out.

**On the default lens**, type its file notes before it is finished. A file's note has its path as its `source`; a folder the default lens draws as one note (past 4,000 files) has the folder's, which is no file's, and stays plain. The whole of it, as [the bookshelf example](../examples/bookshelf/.canvas/lens.py) has it:

```python
from lenskit import default
from lenskit.text import as_text, file_text

FILE = {"type": "object", "properties": {"path": {"type": "string"}, "lines": {"type": "integer"}}, "required": ["path"]}
BANDS = [("Apps", ["web", "api"]), ("Libraries", ["core"])]

def digest(scan, repo):
    d = default.build(scan, repo, bands=BANDS)
    below = 1 + max(n.get("rank", -1) for n in d.nodes if n.get("kind") == "frame" and "in" not in n)   # under every band, an "Other modules" too
    types = d.frame(d.claim("the frame of the types", "Types"), rank=below)
    file_type = d.note(d.claim("the type File", "File", within=types, type=True), types,
                       "A file of the code: its path and how many lines it has.", schema=FILE)
    by_path = {f["path"]: f for f in scan.files.values()}
    for node in d.nodes:
        source = node.get("source")
        f = by_path.get(source) if node.get("kind") == "sticky-note" and isinstance(source, str) else None
        if f is not None:
            node["text"] = as_text(file_text(f, scan.language, length=False)) or None
            node["is"] = file_type["title"]
            node["fieldValues"] = {"path": f["path"], "lines": f["lines"]}
    return d.finish()
```

**In a lens of its own**, make a File note for each file it draws, in a frame of their own on the thing's board, titled as the default lens titles them (`default.file_titles` of the frame's files: a file's name, else the shortest end of its path that tells it apart there), and join each thing to the file it is declared in with a relationship type, `declared in`, its end at each kind of thing Only one. Without that line a board holds two pictures, the things and the files, that nothing joins. [The orders example](../examples/orders/.canvas/lens.py) does it (its rules "files-are-typed" and "things-in-their-files").

**Which file uses which** stays the default lens's plain arrows: a relationship type for it would give every file's note two rows more, and say nothing the arrow doesn't. Ask for them as arrows (`:start-of(arrow:ends-at("client.ts"))`).

**When not to recommend it.** Where the code says the files aren't what the team reads:

- a repository past 4,000 files, where the default lens draws folders as one note each: `:is-a("File")` would quietly miss every file in them, so leave the files plain;
- a repository whose things each fill a file of their own name (a Lambda a handler file): a File beside each would say each thing twice, so give the thing a `path` instead;
- a repository of configuration or data (infrastructure modules, a schema's migrations), read by what it declares, not by the files that hold it.

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
    types = d.frame("Types", rank=1)
    d.note("Service", types, "A service compose runs: its name and image.", schema=SERVICE)
    d.note("needs", types, "A service needs another to start.", schema=NEEDS, relationship=True)
    d.edge("Service", "needs", text="needs")
    d.edge("needs", "Service", text="needed by")
    running = d.frame("Running", rank=0)
    note = {}
    for name in sorted(services):
        values = {"name": name, "image": (services[name] or {}).get("image")}
        note[name] = d.note(d.claim(f"the service {name}", name, within=running), running, as_text(f"{name}"), source=COMPOSE,
                            **{"is": "Service", "fieldValues": {k: v for k, v in values.items() if v}})
    for name in sorted(services):
        for other in sorted((services[name] or {}).get("depends_on") or []):
            if other in note:
                d.edge(note[name], note[other], **{"is": "needs"})
    return d.finish()
```
