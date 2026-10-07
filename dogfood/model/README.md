# Redrawing the model

The model on "the-system" board comes from these scripts. They talk to the running app through main's `build/canvas`, and draw on board 2 (`CANVAS_BOARD` overrides it).

```bash
python3 analyze.py <repo> model.json                                 # files, declarations, first doc sentences
python3 index_build.py <repo> <scratch>/idx                          # type-checks every module into a fresh index store
python3 index_read.py <scratch>/idx/store model.json index_edges.json   # which file uses which, exactly
python3 gen2.py measure <modules>                                    # note heights, on a scratch subboard
python3 gen5.py plan                                                 # each board's plan and which arrows stay
python3 gen5.py reset                                                # deletes what's drawn, and the marks of what was
python3 gen5.py all                                                  # draws what isn't drawn yet (marks in runs/v9-done-*)
GALLERY_CLONE=<clone> python3 check.py gen5                          # the board against the plan, once the app has saved it
```

The first three steps write `model.json` and `index_edges.json`; `measured2.json` keeps the note heights the app measured. `gen5.py` is the current layout. `all` alone picks up a run that stopped; `reset` then `all` redraws.

- Which uses between a board's files are arrows comes from `heuristic.py` ([heuristic-report.md](heuristic-report.md)): every use of a board's hubs, its most-used files, and every arrow that two stronger ones already relay, is a pill. An arrow that would cross more than `ALLOW` lets it (now: pill frames, but no note) is a pill too. `heuristic_check.py` checks the heuristic's promises on every board.
- A frame whose files have arrows between them is a ladder: two columns, the left one's pills on its left, the right one's on its right, the arrows between them. A small search moves and swaps files between the columns while that makes the frame's own arrows cross less.
- Then a search over the whole board (`board_search`) moves the files linked across frames within their ladders, flips ladders and swaps neighbouring frames, while that leaves fewer arrows to make pills, and then less crossing and shorter arrows. It takes a few minutes over every board, so its result is kept in `runs/v9-search.json`, each board's stamped with its frames, uses and note heights: a board whose stamp changed is searched again (delete the file after changing the rules).
- Canvas's board is drawn the same way, its folders' cards in place of notes.
- A note's pills are grouped by where they come from, each group in a frame titled "<where> (<note>)" (on the root, by layer), the pills 16 apart. Draw stacks a start's pills 96 apart, so a board's notes are drawn first in a staging area beside it; each pill is put in a temporary 40-tall frame (`overlap: allow` takes it in), the frames move where the pills go and are deleted, the group frames go down around the groups, and the notes go home.
- On the root (`root_decide`), an import is an arrow when it clears every shape after a small bend and its module takes six arrows or fewer. It has no legend: its shapes hang from a temporary note, deleted once its pills are home.

`check.py` reads every board's shapes from the file of the board drawn on (`CANVAS_BOARD`), once the app has saved it, through the gallery test's dump, and compares each with the plan. `gen2.py` holds the shared geometry and the measuring; `gen.py` the model and the runner.

`spec.py` holds what the code doesn't say: the layer bands, each module's purpose, and how files group into frames. `GalleryCapture.swift.txt` is the throwaway test that renders boards to PNGs and, with `GALLERY_DUMP`, writes every board's shapes. Register it in a scratch clone's CompositionTests (`check.py` finds that clone through `GALLERY_CLONE`) and run `GALLERY_FILE=… GALLERY_OUT=… TEST_FILTER=Gallery build/debug/CompositionTests/CompositionTests`.
