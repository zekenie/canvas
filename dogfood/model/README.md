# Drawing a codebase

These scripts draw a codebase as boards, through `canvas draw`: the root holds its modules in bands by layer, each module's board holds its files as notes in frames, and which file uses which is an arrow or a pill. They drew "the-system" board from this repo, and they draw a TypeScript, Python or Ruby project from a SCIP index. They talk to the running app through main's `build/canvas` (`CANVAS_CLI` overrides it) and draw on board 2 (`CANVAS_BOARD` overrides it).

A project is a directory, `PROJECT` (this one, Infinite Canvas's, when unset). It holds `model.json`, which a reader writes, and optionally `spec.py`. The scripts write `measured.json` (note heights) and `runs/` there.

## Reading the code

A reader writes `model.json`, the only thing the layout reads of the code. There's one reader for Swift, and one for any language a SCIP indexer covers.

```bash
# Swift, a package: files and declarations from the sources, uses from the compiler's index
python3 swift_analyze.py <repo> <project>/model.json
python3 swift_index_build.py <repo> <scratch>                 # this repo's way to a store (SwiftPM can't build here)
python3 swift_index_read.py <scratch>/store <project>/model.json

# TypeScript, Python, Ruby: run the language's SCIP indexer, then read its index
npx @sourcegraph/scip-typescript index tsconfig.json          # or scip-python, scip-ruby
python3 scip_read.py index.scip <repo> <project>/model.json
```

A project Xcode or `swift build` builds has an index store already (DerivedData's `Index.noindex/DataStore`, or `.build`'s `index/store`); `swift_index_read.py` reads any. `swift_index_build.py` type-checks a package whose targets need nothing but each other.

`scip_read.py` takes the index's packages as modules. A project of one package is split by the folders under its sources' root, its own files making a module named after the package. A module imports another when one of its files uses one of the other's. What a file exports and how it describes itself come from its source, by its language's conventions: TypeScript's `export` and first block comment, Python's leading underscore and module docstring, Ruby's first comment. `scip.py` decodes the index with no dependencies.

## model.json

```
language    "swift", "typescript", ...: the words a note uses (gen.py's WORDS)
modules     [{name, path, deps: [module], test, layer: a tag or null, files: [rel], lines, doc, folders: {folder: doc}}]
files       [{module, rel (its path in its module), path, lines, doc, api, decls: [{name, kind, visibility, line}]}]
uses        [{from: [module, rel], to: [module, rel], names: [what it uses]}]
```

A declaration's `kind` is `type`, `function`, `extension`, `value` or `other`. Its `visibility` is `public` (another module may use it), `internal` (its module's other files may) or `private` (its file only), and a file's `api` says it declares something public. A `doc` is a first sentence. Test modules are read but not drawn.

## spec.py, and what's worked out without it

`spec.py` says what the code doesn't. A name it leaves out is worked out from the model (`defaults.py`):

- `BANDS`, the root's bands: by the modules' layer tags when every module has one, else by how deep each module's imports go (an import cycle's modules share a band).
- `PURPOSES` and `FOLDER_PURPOSES`: what the reader found, a README's first sentence or the doc of the file named like the module or folder.
- `FOLDER_BOARDS`, the folders of a module that get boards of their own: in a module of more than 50 files, each top folder, when it has two or more.
- `GROUPS`, a board's frames: its files by folder, two deep, each titled by the shortest end of its folder's path that no other frame, module or board takes (`cors`, but `middleware/jwt` beside `utils/jwt`).
- `BY_MODULE` (files whose pills stand for modules) and `LAYER_NAMES` (how a tag reads): none.

Infinite Canvas's `spec.py` has them all, Canvas's eight folder boards among them.

## Drawing

```bash
python3 gen2.py measure <modules>                                    # note heights, on a scratch subboard
python3 gen5.py plan                                                 # each board's plan and which arrows stay
python3 gen5.py reset                                                # deletes what's drawn, and the marks of what was
python3 gen5.py all                                                  # draws what isn't drawn yet (marks in runs/v9-done-*)
GALLERY_CLONE=<clone> python3 check.py gen5                          # the board against the plan, once the app has saved it
```

`gen5.py` is the layout. `all` alone picks up a run that stopped; `reset` then `all` redraws. A new project needs a board file of its own: `canvas new <file>` makes one and opens it, and the `id` it answers is the `CANVAS_BOARD` to pass.

- Which uses between a board's files are arrows comes from `heuristic.py` ([heuristic-report.md](heuristic-report.md)): every use of a board's hubs, its most-used files, and every arrow that two stronger ones already relay, is a pill. An arrow that would cross more than `ALLOW` lets it (now: pill frames, but no note) is a pill too. `heuristic_check.py` checks the heuristic's promises on every board.
- A frame whose files have arrows between them is a ladder: two columns, the left one's pills on its left, the right one's on its right, the arrows between them. A small search moves and swaps files between the columns while that makes the frame's own arrows cross less, on a ladder of up to 10 files (`LADDER_SEARCH`: past a dozen it takes minutes, so a folder of many files with no spec keeps its first split).
- Then a search over the whole board (`board_search`) moves the files linked across frames within their ladders, flips ladders and swaps neighbouring frames, while that leaves fewer arrows to make pills, and then less crossing and shorter arrows. It takes a few minutes over every board, so its result is kept in `runs/v9-search.json`, each board's stamped with its frames, uses and note heights: a board whose stamp changed is searched again (delete the file after changing the rules).
- A module with folder boards (Canvas) has its folders' cards on its board, in place of their files' notes.
- A note's pills are grouped by where they come from, each group in a frame titled "<where> (<note>)" (on the root, by layer), 16 between its pills. Draw stacks a start's pills 96 apart, so a board's notes are drawn first in a staging area beside it; each pill is put in a temporary 40-tall frame (`overlap: allow` takes it in), the frames move where the pills go and are deleted, the group frames go down around the groups, and the notes go home.
- On the root (`root_decide`), an import is an arrow when it clears every shape after a small bend and its module takes six arrows or fewer. It has no legend: its shapes hang from a temporary note, deleted once its pills are home.
- A file's title is its name, else its module's and its name, else the shortest end of its path no other file could take (`cors/index.ts`).

`check.py` reads every board's shapes from the file of the board drawn on (`CANVAS_BOARD`), once the app has saved it, through the gallery test's dump, and compares each with the plan. `gen2.py` holds the geometry and the measuring, and `gen.py` the model and the runner.

`GalleryCapture.swift.txt` is the throwaway test that renders boards to PNGs and, with `GALLERY_DUMP`, writes every board's shapes. Register it in a scratch clone's CompositionTests (`check.py` finds that clone through `GALLERY_CLONE`) and run `GALLERY_FILE=… GALLERY_OUT=… TEST_FILTER=Gallery build/debug/CompositionTests/CompositionTests`.
