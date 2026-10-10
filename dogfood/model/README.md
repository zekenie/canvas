# Drawing a codebase

`ingest` draws a codebase as boards in one command: it reads the code into `model.json`, makes it a digest (`to_digest.py`) and has the canvas-digest skill measure, lay out and draw it (`.claude/skills/canvas-digest`, `digest all`). The root holds the modules as cards in bands, one band a layer, top to bottom; a module's board holds its files as notes in frames; which file uses which, and which module imports which, is an arrow or a pill, as the skill decides ([its rules](../../.claude/rules/digest.md)). It draws this repo, and a TypeScript, Python or Ruby project from a SCIP index.

```bash
dogfood/model/ingest                                   # this repo, onto the board in front
dogfood/model/ingest --new-file ~/Documents/Code.canvasboard
dogfood/model/ingest <repo> --scip index.scip          # another language's project (below: making the index)
```

- **Nothing by hand.** The board is what the code says: its title the name the reader found, its bands the layers the code tags (or how deep each module's imports go), a board's frames its folders. This repository has no `spec.py`; a project may keep one of overrides (below).
- **Where it draws.** It asks first, before reading anything, whether the app is running and the board can take the drawing. The board in front, as that board: when it's empty, or when it holds the last ingestion and nothing else, which is taken back first (one Edit › Undo Draw brings it back) and drawn anew. A board with anything else on it (a note or an arrow drawn since) is refused before anything is taken back, never drawn among. `--board ID` names another open board, and `--new-file PATH` makes a new board file and draws there; a later run with that board in front draws in its place. A run that stops part way can simply be run again, whether or not you undid what it drew. What a run drew is remembered in the project (`digest.out/drawn.json`), so it is this checkout's: a board drawn from another checkout, or before `digest.out` was removed, reads as not empty here, and the way on is an empty board in front or `--new-file`.
- **How long.** About a quarter of a minute here when the code is as the last run read it, and up to half a minute when it isn't: measuring, laying out and drawing the 6,000 shapes takes about fifteen seconds, and Swift's index up to fifteen more. The index is kept from run to run (`.index/`), and only the modules that changed are type-checked again: none after no change, one after an edit inside a function, and the modules that depend on it too after an edit to what a module declares. A project's first run also asks the compiler which SDK it accepts, some ten seconds (and so does the first with another compiler or `SDKROOT`). Deleting `.index/` starts the index over. It says each step as it starts, and each script as it lands (`[n/146] ok ...`). `--skip-read` draws from the `model.json` there is; a read that stops part way leaves that model as it was (the readers write `model.json.reading`, which takes its place only when whole).
- **What it needs.** The app running, and `canvas`: `$CANVAS_CLI`, else the repository's `build/canvas`, else the one on the PATH. Run from a worktree, point `CANVAS_CLI` at main's `build/canvas`, the app that's running.

A project is a directory, `PROJECT` (this one, Infinite Canvas's, when unset). It holds `model.json`, which a reader writes, and optionally `spec.py`. A run writes `digest.json`, `digest.out/` (the skill's plan, report, scripts and what the app said of each, and `drawn.json`, what the next run takes back) and, for Swift, `.index/` there.

## Reading the code

A reader writes `model.json`, the only thing the digest is made from. There's one reader for Swift, and one for any language a SCIP indexer covers; `ingest` runs Swift's when the repository has a `Package.swift`, and SCIP's with `--scip`. By hand:

```bash
# Swift, a package: files and declarations from the sources, uses from the compiler's index
python3 swift_analyze.py <repo> <project>/model.json
python3 swift_index_build.py <repo> <scratch>                 # this repo's way to an index (SwiftPM can't build here): a store a module
python3 swift_index_read.py <scratch>/store <project>/model.json

# TypeScript, Python, Ruby: run the language's SCIP indexer, then read its index
npx @sourcegraph/scip-typescript index tsconfig.json          # or scip-python, scip-ruby
python3 scip_read.py index.scip <repo> <project>/model.json
```

A project Xcode or `swift build` builds has an index store already (DerivedData's `Index.noindex/DataStore`, or `.build`'s `index/store`); `swift_index_read.py` reads any, one store or a folder of them. `swift_index_build.py` type-checks a package whose targets need nothing but each other, a module a compile, into a store of its own (`<scratch>/store/<Module>`), and keeps each with a hash of what it was made from (the compiler, the command, the module's sources and the interfaces of the modules `Package.swift` says it depends on), so a module is type-checked again only when one of those changed; it says which it made. A compile is given only the interfaces of the modules `Package.swift` says its module depends on, so an import that isn't declared there fails (`no such module`), as it should in a build. A line that ends `+ shipped`, as this repository writes its app's and the tests of what it ships, depends for a compile on every module of the plugins its table of what ships names (`let ships = [`); the model keeps only what the line itself writes, so the board draws no arrow from the app to every plugin.

`scip_read.py` takes the index's packages as modules. A project of one package is split by the folders under its sources' root, its own files making a module named after the package. A module imports another when one of its files uses one of the other's. What a file exports and how it describes itself come from its source, by its language's conventions: TypeScript's `export` and first block comment, Python's leading underscore and module docstring, Ruby's first comment. `scip.py` decodes the index with no dependencies.

## model.json

```
language    "swift", "typescript", ...: the words a note uses (common.py's WORDS)
name        what the code calls itself: a Swift package's name, else the repository's folder
modules     [{name, path, deps: [module], test, layer: a tag or null, files: [rel], lines, doc, folders: {folder: doc}}]
files       [{module, rel (its path in its module), path, lines, doc, api, decls: [{name, kind, visibility, line}]}]
uses        [{from: [module, rel], to: [module, rel], names: [what it uses]}]
```

A declaration's `kind` is `type`, `function`, `extension`, `value` or `other`. Its `visibility` is `public` (another module may use it), `internal` (its module's other files may) or `private` (its file only), and a file's `api` says it declares something public. A `doc` is a first sentence. Test modules are read but not drawn.

## spec.py, and what's worked out without it

`spec.py` says what the code doesn't, as overrides: whatever it leaves out is worked out from the model (`defaults.py`), and what it names that the code no longer has is passed over. Each is said on standard error, and none stops the run: a module its `BANDS` leave out goes in the band of its layer tag, else a band of its own at the bottom ("Other modules"); a file its `GROUPS` leave out goes in a frame of its own on its board (`Automation/`).

- `TITLE`, what the whole is called (the root's header, `About <TITLE>`): the name the reader found (a Swift package's own, else the repository's folder).
- `BANDS`, the root's bands, top to bottom: by the modules' layer tags when every module has one, else by how deep each module's imports go (an import cycle's modules share a band).
- `PURPOSES` and `FOLDER_PURPOSES`: what the reader found, a README's first sentence or the doc of the file named like the module or folder.
- `FOLDER_BOARDS`, the folders of a module that get boards of their own: in a module of more than 50 files, each top folder, when it has two or more.
- `GROUPS`, a board's frames: its files by folder, two deep, each titled by the shortest end of its folder's path that no other frame, module or board takes (`cors`, but `middleware/jwt` beside `utils/jwt`).
- `BY_MODULE` (files whose uses point at modules, not files) and `LAYER_NAMES` (how a tag reads): none.

Infinite Canvas has no `spec.py`: its board is what its code says, as any other codebase's is.

## The digest

`to_digest.py` makes the digest the skill reads ([its format](../../.claude/skills/canvas-digest/reference/graph.md)) from the model and the spec:

- each band a frame on the root with its `rank` (the skill stacks ranked frames in rank order, each as wide as the widest), each module a subboard in its band, and each folder board a subboard on its module's board;
- each group a frame, nested as the spec nests them, and each file a note in its frame, titled by its name (else its module's and its name, else the shortest end of its path no other file could take) and saying its doc, what it declares and how long it is (`common.file_text`);
- every title given out once, a module's first, then a folder board's, a band's, a file's and a frame's: one that another shape has (case aside), or that is over 80 characters, is reworded (a band `Level 1 (layer)`, a file its whole path, a frame `utils (Core)`, then a number; a long one keeps its end behind an ellipsis), which is said on standard error and never stops the run;
- a board's header note, its card's `text`: a module's layer, purpose, imports (as mentions of their cards, a `]` or `\` in a title escaped), importers and size (`common.about_text`), and for the root what the whole is;
- an edge for each module's import of another, and for each file's use of another, as heavy as the names it uses (up to 4); a use of a file on another board is a pill there, and that file is public. A `BY_MODULE` file's edges go to the modules it uses.

Test modules are read but not drawn.
