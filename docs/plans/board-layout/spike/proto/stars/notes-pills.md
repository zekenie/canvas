# pills2: pill lines bend a little, strips are short

Kit: `kit.mjs` (from dir-pills/kit.mjs; every export and its contract kept; `pillBend` takes an optional 4th argument, the user whose
pills count as its own). Test copies: `module.mjs`, `worker.mjs` (stars4's, importing `./kit.mjs`), `wrap.mjs` (stars4's wrapper, shared
pills after it, plus the pill measures in `info.pills`), `stats.mjs` (the measures), `dstats.mjs` (the measures of any drawing.json).

## What changed

1. A pill's line bends at most a little: `pillBend` tries only arcs up to min(0.25 x chord, 120) (`KIT.pillBendShare`, `KIT.pillBendMost`),
   in steps of 0.02 of the chord. The first clear one wins; when none is clear, the slight arc over none but the note's own pills and fewest
   of them (straight first) wins: a short line over its own pill instead of a loop. Only if every slight arc is blocked by something else
   (another note or another note's pill) are the old big arcs tried, so the board stays clean.
2. Strips are short: `KIT.stripMost` 12 -> 8 (a column), `KIT.rowMost` 8 -> 6 (a row). A note with more pills is laid out by the best of
   the old arrangements and a new `grid`: rows below and above (2, 3, 4, 6 or 8 pills a side, tried), each row no wider than the columns'
   outer edges so its lines come out steep and over no column, stacked outward when too narrow; the rest in columns of at most 8, on the
   side the placement asked for, then the other side, further columns outward only past that. Any arrangement with a strip over 8 is out
   while one keeps every strip within it (the grid always does). Among the rest: 3 x lines over own pills (judged with the slight arcs the
   board will draw) + area.

## Numbers (before = the reviewed build, run/stars4/drawing.json; after = this kit; from the drawings as the app gets them, dstats.mjs)

The seven named boards (Types/Type, Validation, Publishing, Queries, Types, StickyNotes, Selection):

| | before | after |
|---|---|---|
| largest pill-line bend | 2199 | 119 |
| pill lines bent over 120 | 175 | 0 |
| pill lines bent over a quarter of their chord | 285 | 1 |
| longest strip (pills) | 31 | 8 |
| lines over own pills | 127 | 498 |
| area (M units^2) | 86 | 79 |
| sum of each board's longest arrow | 17,202 | 6,838 |

All 71 boards (full build: out-full/; verify.mjs: 71 of 71 clean, every overlap 0; nothing failed):

| | before | after |
|---|---|---|
| largest pill-line bend | 2199 | 120 |
| pill lines bent over 120 | 835 | 0 |
| pill lines bent over a quarter of their chord | 1382 | 12 (short chords, where the 0.02 step rounds past) |
| longest strip / boards with a strip over 8 | 31 / 51 | 8 / 0 |
| lines over own pills | 832 | 2499 |
| area, total (M units^2) / median vs today | 449 / x1.04 | 476 / x1.06 |
| sum of each board's longest arrow (pill lines included) | 81,226 | 47,252 |

## What's still weak

- Lines over own pills tripled (832 -> 2499): the price of short strips and no loops. A note with 30+ pills (TypesPlugin.swift 62,
  StickyNotes.swift, Selection.swift, Evaluation.swift on Queries) is now a compact block: rows stacked above and below, two or three
  columns a side, and the lines to the outer ones run straight over the inner ones, a dense hatch around the note (Types, Selection).
  It reads better than the brackets of semicircles, but it is not what a person would draw. Next: space the outer columns and rows so
  a line threads the gaps between the inner pills (stagger them), or fan the outer layer.
- A row stacked above a note fans its lines up through the row below it (Evaluation.swift, Selection.swift).
- Board placement (the module, not the kit) still leaves some long note-to-note arcs and a few stray notes (Validation's
  IssueRowValues.swift below the frame; Selection's Labels.swift and Accessibility.swift at the bottom).
- Area rose a little (total +6%), from strips on more sides.

Pictures (label pills2): out/<Board>-pills2-fit.png, -pills2.png and -vs-today for Types/Type (TypesType), Validation, Publishing,
Queries, Types, StickyNotes, Selection.
