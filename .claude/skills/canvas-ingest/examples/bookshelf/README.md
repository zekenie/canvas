# The bookshelf example

An ordinary TypeScript repository, set up for `ingest` the usual way: its settings, `.canvas/ingest.json`, and a lens, `.canvas/lens.py`, that is the default lens with its bands named and every file a note of the type File. Start from it for a repository whose picture is its packages and files; [the orders example](../orders/README.md) is the one for a repository whose picture is things of its own (workflows, Lambdas, tables), and it types its files too.

- `packages/shared`: a book, a member, a loan, and the days a loan keeps.
- `apps/api`: the HTTP API: a small router, the routes (`routes/`) and each table's functions (`db/`).
- `apps/web`: the web app: its pages (`pages/`), its calls to the API, and the pieces a page is drawn with.

The lens draws the root with the apps over the library they share, as two bands of cards, and the types at the bottom. A package's board is the default lens's: its files as notes in frames by folder, and which file uses which as arrows, a use of a file on another board as a pill. Every file's note is a File, with its path and how many lines it has as values, and its words are its doc and what it declares. Its two decisions are named rules at the top of the lens, with their reasons.

`scan.json` is the scan, written for this example in the scan format (`reference/scan.md`): what scip-typescript and `scanners/scip_read.py` would make of the code. On a real repository `ingest` makes the scan itself, with the `scip` command in the settings. The example has no `package-lock.json`, so its `prepare` (`npm ci`) would fail as it is; a real repository has one.

To draw it, copy it into a git repository of its own and commit it, then draw it from its scan, with an empty board in front (`$SKILL` is the skill's folder):

```bash
cp -R "$SKILL/examples/bookshelf" ~/bookshelf && cd ~/bookshelf && rm scan.json
git init -q && git add -A && git commit -qm "the bookshelf example"
"$SKILL/ingest" --scan "$SKILL/examples/bookshelf/scan.json"
```

## What it answers

Each block is a `canvas query`, and its first line says what it answers on the drawn board.

The files:

```query
/* count: 20 */
:is-a("File")
```

The files over 20 lines:

```query
/* matches: "router.ts", "loans.ts", "api.ts", "view.ts" */
:is-a("File")[fieldValues.lines>20]
```

The API's routes, by where their files are:

```query
/* matches: "books.ts", "loans.ts", "members.ts" */
:is-a("File")[fieldValues.path^="apps/api/src/routes/"]
```

The long files of the API alone:

```query
/* matches: "router.ts", "loans.ts" */
:is-a("File")[fieldValues.path^="apps/api/"][fieldValues.lines>20]
```

What goes through the database client:

```query
/* matches: "books.ts", "loans.ts", "members.ts" */
:start-of(arrow:ends-at("client.ts"))
```

Who uses a loan, on any board (a use of a file on another board is a pill, and a query reads it as the file):

```query
/* matches: "loans.ts", "api.ts", "member.ts", "index.ts" */
:start-of(arrow:ends-at("loan.ts"))
```

## What the lens does not read

- **A folder drawn as one note is no file.** Past 4,000 files the default lens draws a folder's files as one note; that note stays plain, and `:is-a("File")` doesn't list it or its files.
- **Which file uses which is the default lens's arrows, untyped.** A relationship type for them would give every file's note two rows more and say nothing the arrow doesn't; ask for them as arrows (`:start-of(arrow:ends-at("client.ts"))`).
- **A package is a card, never a note of a type**: a subboard can't be one.
