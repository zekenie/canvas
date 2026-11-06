---
name: canvas-ingest
description: Draw a git repository's code as boards in Infinite Canvas, and set a repository up for it with its team over a few rounds. `ingest` scans a commit, the repository's own lens (`.canvas/lens.py`) turns the scan into a graph document keyed by the code, with types (workflows, Lambdas, tables, services) and relationships between them, and canvas-digest draws it in the running app, so a question like "which workflows write the orders table?" is a `canvas query`. Use when asked to "draw this codebase", "map this repo onto a board", "ingest this repository", "set this repo up for the canvas", to redraw a repository's boards, to draw a commit or a branch as a proposal, or to change how its board looks ("workflows on top", "one frame of tables per service"). NOT for information that isn't a codebase (that is canvas-digest), NOT for a few shapes by hand (that is the canvas skill), NOT for changing a board someone wrote on.
---

# canvas-ingest

`ingest` draws a commit of a git repository as boards, in the app that is running: it scans the commit's code, the repository's lens turns the scan into a graph document (nodes keyed by the code: `file:<path>`, `module:<name>`, `table:<name>`), and canvas-digest lays the document out and draws it. The app keeps the drawing's record by its name, so drawing again updates the board in place. The repository keeps two files for it, and nothing else: `.canvas/ingest.json`, how its code is scanned, and `.canvas/lens.py`, what its board shows. What a run makes is kept in a cache outside the repository.

`ingest` is the script in this skill's folder. Run it by its path, from inside the repository you draw (or name the repository as its first argument). Below, `$SKILL` is the folder this file is in (where your agent loaded the skill from; `canvas install` puts a copy in `~/.agents/skills/canvas-ingest`):

```bash
SKILL=~/.agents/skills/canvas-ingest      # or wherever this SKILL.md is
"$SKILL/ingest" --help
```

It needs `canvas`, the canvas skill's command, and the app running. Its Python is `/usr/bin/python3`; nothing is installed. The repository's `prepare` and `scip` commands run in a shell with your PATH.

## Before anything

1. **Check the app**, as the canvas skill says ([Check the app](../canvas/SKILL.md#check-the-app)): `canvas status`, then `canvas boards`. If it isn't running, ask the user to open Infinite Canvas.
2. **Know where it will draw.** In the file `--board ID` names (an id from `canvas boards`; pass it every run, since the file in front changes when the user clicks another window), on its root or the board `--on NAME` names (a subboard's title, path or `#id`). The app keeps the drawing by its name (the settings' `drawing`, `--drawing`, else the lens's, else the repository's): drawing again updates the shapes it made, by key, and deletes the ones whose keys are gone. It touches nothing that isn't the drawing's, so a person's notes stay, and the shapes of the drawing that a person moved or edited are drawn as the code says again (the run's `overrode` lists them: tell the user). For a new file, `canvas new PATH` first (it answers with the file's `id`). Never delete a user's shapes yourself.
3. **Know which code it draws.** A commit, `HEAD` unless `--commit` says another, never the working tree. An uncommitted change to the code doesn't show: tell the user. The code is theirs to commit; you never commit in their repository unasked.
4. **Know what it runs.** `ingest` runs the repository's own code, as its build would: `prepare` and the `scip` command from `.canvas/ingest.json`, with the user's environment, and `.canvas/lens.py`, isolated but not sandboxed. Before the first run on a repository the user didn't set up, show them those commands and the lens, and ask.

## Setting a repository up: round one

1. **Survey the repository.** Read it; don't build it. Find the languages, the package manager and its workspaces (`package.json`'s `workspaces`, `pnpm-workspace.yaml`, the lockfile), the frameworks, and the repository's own conventions for what matters: Temporal workflows and activities (`proxyActivities`, `workflows/` and `activities/` folders, `Worker.create` and its `taskQueue`), Lambdas (`serverless.yml`'s `functions`, CDK's `NodejsFunction`, SAM's `template.yaml`), tables (SQL migrations' `CREATE TABLE`, `schema.prisma`, TypeORM's `@Entity`), HTTP controllers, queues and jobs, and what a service is (a folder under `services/` or `apps/`, a deployable package).
2. **Recommend a picture**, each part with its reason in the code (how it is found, a count, an example):
   - **the things**: "Temporal workflows: 14, the exported functions of `services/*/src/workflows/*.ts` (`checkoutWorkflow` in `services/orders/src/workflows/checkout.ts`, …)";
   - **which kinds get types**: those a question is asked about (tables, workflows);
   - **files**: usually notes of the type File, with their path and length, on their package's board, each thing joined to the file it is declared in, so a question about files is a query. Recommend otherwise only where the code says so ([lens.md](reference/lens.md#files-as-a-type));
   - **which relationships matter**: those a question follows (`runs`, `reads`, `writes`);
   - **what to leave out**: generated code, vendored packages, what no one reads.

   Say what is unclear: two conventions for one kind, files that fit none.
3. **Ask only where the code leaves a real choice open**, one question at a time: which of two conventions is the real one, whether a kind matters to the team, what counts as a service. Decide the rest yourself, and say what you decided and why.
4. **Write `.canvas/ingest.json`:**

   ```json
   {
     "scanner": "scip",
     "scip": "npx --yes @sourcegraph/scip-typescript@0.4.0 index packages/db services/orders --output {index}",
     "prepare": "npm ci --ignore-scripts",
     "window": [1440, 900]
   }
   ```

   - `scanner`: `swift` for a Swift package, else `scip`, with `scip` the command that writes a SCIP index to `{index}`, run at the repository's root, the indexer's version pinned (scip-typescript takes a workspace's project folders, or `--yarn-workspaces` or `--pnpm-workspaces`; scip-python and scip-ruby for those languages).
   - `prepare`: what installs the packages before a scan (`npm ci --ignore-scripts`, `pnpm install --frozen-lockfile --ignore-scripts`, `yarn install --immutable --mode=skip-build`), with the package manager's version the repository pins: a frozen install that fails on a lockfile mismatch is usually another version (`npx --yes pnpm@9 install ...`). It runs in the cache's checkout, again only when a lockfile changes. A workspace whose packages import each other through built files (`dist/`) also needs them built here, or mapped to their sources ([scan.md](reference/scan.md#workspaces-that-resolve-through-built-files)): the scan says when it barely connects the packages.
   - `drawing`: optional, the drawing's name (the app keeps its record by it); left out, it is the repository's folder name. A second name is a second drawing in the same file.
   - `window`: the room every board is laid out for, set once from the window in front: `canvas boards` gives the board in front's `view`, `[width, height]`; write that. With it, every run lays out alike, whatever window is open then.

   [reference/scan.md](reference/scan.md) has every key and option. Leave the file uncommitted: it is read from the working tree.
5. **Write `.canvas/lens.py`**, a function `digest(scan, repo)` that returns the graph document. For a repository whose picture is its modules and files, build on the default lens with arguments (`lenskit.default.build(scan, repo, bands=[...])`) and type its files (`file:<path>` notes): start from [examples/bookshelf](examples/bookshelf/README.md) and its [lens](examples/bookshelf/.canvas/lens.py). The default lens bands modules by their imports, so modules that don't import each other (samples, independent services) come out as one band. For one whose picture is its things, write a lens of its own with `lenskit.Graph`: a type for each kind in the picture (Workflow, Lambda, Table, File), a node of it for each thing, keyed by the code (`workflow:<file>#<name>`) and titled by its name, with its values, relationship types for how they connect (`runs`, `reads`, `writes`, `declared in`), all found by the conventions you listed, through `repo` and the scan: start from [examples/orders](examples/orders/README.md) and its [lens](examples/orders/.canvas/lens.py). Write each decision of the picture as a named rule ([Later rounds](#later-rounds-art-direction)). [reference/lens.md](reference/lens.md) has lenskit, types and the rules; what a kind takes is `canvas kinds`, not the lens's to decide (the app says no to what it won't take). Leave it uncommitted as well; say in the lens's docstring what its conventions don't read ([lens.md](reference/lens.md#what-a-lenss-conventions-miss)).
6. **Draw HEAD**: `"$SKILL/ingest"` with the file to draw in in front (`canvas new ~/Boards/shop.canvasboard` makes one). The first run of a repository installs and indexes, which can take minutes. A later run on the same code reuses its scan, whatever `.canvas/` holds.
7. **Read the run before the user looks.** What `ingest` printed:
   - `scan:` lines, what the index left out: source files no project takes in, and packages it couldn't connect (fix the settings, and draw again);
   - `lens:` lines, what the lens warned of (a handler not found, a folder left out of a group);
   - what `digest all` printed: `check`'s warnings (a frame over 15 shapes, a board over 150), the plan's boards, shapes and pills and what was promoted and fanned out (a board `laid out once and not searched` is too crowded to read: split it in the lens), and what `apply` did: created, updated, unchanged and deleted shapes, what it overrode, and the app's own warnings (a Needed row still empty, by design) ([canvas-digest](../canvas-digest/SKILL.md)).

   For more, the run's folder: `"$SKILL/ingest" --where` prints the cache, and the newest folder in its `runs/` has `graph.json` (what the lens made) and `out/` (the measure, the plan, the apply document and what the app answered). Fix the obvious in the lens (split a crowded frame, add a missed kind) and draw again: it updates its own last drawing in place.
8. **Show it.** Tell the user what is on the root and on each board, the counts, what was promoted and fanned out, and the types, with queries they can ask (`:is-a("Workflow")`, `:start-of(arrow:is-a("writes"):ends-at("orders"))`, `:is-a("File")[fieldValues.lines>500]`). Say what the lens left out. Then ask what to change.

## Later rounds: art direction

1. **Take the request** ("workflows on top", "one frame of tables per service", "too crowded"). A lens that draws files as plain notes, or leaves them out with no rule saying why, predates files as a type: recommend them as round one would, and write a yes as a named rule.
2. **When the user points at shapes**, read what they selected:

   ```bash
   canvas query - <<'EOF'
   :selected
   EOF
   ```

   Each row has the shape's `title`, `kind`, `board` and what it is `inside`. Find the node of that title in the run's `graph.json`: its key says what it was made from (`file:<path>`, `workflow:<path>#<name>`). Several nodes can have one title (an `index.ts` in each of two folders): the row's `inside` (the shape's containers) says which.
3. **Write the request as a named rule in the lens**: a name for what it does, the reason in the user's words, and the round. Read the rules already there first. If the request goes against one, name that rule and its reason, and ask which wins; then change that rule, and never add one that undoes it. Make it general: a user pointing at one shape is showing a case.
4. **Draw again**: `"$SKILL/ingest" --board ID`, the same file. The lens and the settings are read from the working tree, so a round needs no commit: edit `.canvas/lens.py` and run again. A round runs only the lens and the drawing; the scan is kept for the commit's code, and a commit that changes only `.canvas/` has the same code. The drawing is updated by key: a shape the lens still has stays the shape it was (a user's note beside it stays), one it dropped is deleted, and one the user moved or edited is drawn as the lens says again, which the run says (`overrode`): tell the user, and for a round they want to compare, draw it as a second drawing (`--drawing NAME`).

When the user is happy with the picture, offer to commit `.canvas/ingest.json` and `.canvas/lens.py` so the team has them; commit only if they say yes.

How tidy a board is, as a whole, is the `mess` setting (0 tidy to 1 loose), and which way the root's bands run is `ranks`: settings, not rules.

## Any commit, and proposals

- `--commit REF` draws a commit, a branch or a tag: that commit's code, with the settings and lens of the folder you run in. The same commit, lens, app and macOS draw the same boards. An older commit runs today's `prepare` and `scip` on its code: an older lockfile can need other options, and the error names the command. In a partial clone what the commit lacks is fetched first; a shallow clone has no older commits (`git fetch --unshallow`).
- A proposal is a commit drawn as a drawing of its own, which people then write on: in a new file (`canvas new ~/Boards/split-billing.canvasboard`, then `"$SKILL/ingest" --commit feature/split-billing`), or beside the code's own drawing in the same file (`--commit feature/split-billing --drawing shop-split-billing --on "Proposals"`).
- Drawing again touches only the drawing's own shapes, by key, so what people wrote beside it stays. A later commit drawn with the same name updates the board to that commit's code.

## Keeping the lens deterministic

`ingest` runs the lens twice, each isolated, and refuses it when the two documents differ, naming the first node or edge that differs. Keys are the code's, the same from commit to commit, never numbered by the run. So a lens:

- reads the code only through `repo` (the commit), never `open()` or the working tree;
- sorts what it iterates: a set, a dict built from one, a folder's listing;
- reads no clock;
- reads no environment: no `os.environ`, `HOME`, current folder, user or host;
- uses no network and no randomness.

It runs on Python 3.9: no `match`, no `X | Y` types, no `tomllib`, nothing installed. `ingest` also refuses a lens that raises (it prints the traceback), a document whose structure is wrong (a key twice, an `in` or an edge end that names no key) or with a value JSON can't hold (a set), a lens that runs over 900 seconds, and a `.canvas/spec.py` (its names go into `lens.py` as the default lens's arguments).

## When things go wrong

- **Another ingest is running** ("another ingest of this repository is running (pid N)"): wait for it, or ask the user whether to stop it. A lock whose process is gone is taken over by the next run.
- **The app isn't running**: ask the user to open Infinite Canvas, then run again. The scan and the lens already ran and the scan is kept, so the next run costs the lens and the drawing only.
- **The app refuses a value** (`digest all` stops before drawing anything, naming the node's key and the app's words): the lens wrote something the kind doesn't take. Fix it in the lens (`canvas kinds` says what a kind takes), and draw again. Nothing was drawn: a draw is all or nothing.
- **The lens is refused because its two runs differ**: look at the node or edge it names, find which of the causes above made it differ, fix it, run again.
- **The lens raised**: its traceback names the line of `lens.py`.
- **The scan fails.** `prepare` failed: its output is above the error; try the command in the cache's checkout (`<cache>/checkout`, the cache from `--where`). The `scip` command failed: check the indexer's version and arguments (a project folder with no `tsconfig.json`), or index fewer projects. "no scanner": write `.canvas/ingest.json`. A scan is kept for each commit's code; `--rescan` makes it again.

## Reference

- [reference/scan.md](reference/scan.md): every option and setting, the cache and its checkout, the scanners, the scan's format, and the default lens's document.
- [reference/lens.md](reference/lens.md): writing a lens: lenskit, types in a document, named rules, determinism, Python 3.9, a short lens.
- [examples/bookshelf](examples/bookshelf/README.md): the usual setup, a TypeScript monorepo drawn as its packages and files, every file a File: its settings, its lens and the queries it answers.
- [examples/orders](examples/orders/README.md): a TypeScript monorepo with Temporal, Lambdas and Postgres drawn as its own things and their files, its service frames typed: its settings, its lens and the queries it answers.
- canvas-digest's [graph.md](../canvas-digest/reference/graph.md): the graph document's format, and its [Types](../canvas-digest/reference/graph.md#types).
- The canvas skill's [query reference](../canvas/reference/query.md) and [relationships](../canvas/reference/relationships.md): asking the drawn board.
