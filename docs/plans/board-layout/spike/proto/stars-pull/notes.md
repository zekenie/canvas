# stars5: placement

## What changed
`module.mjs` = dir-stars4 plus `pull()`, run at the end of `layoutOne`, so it runs on all eight configurations and the scoring sees the result. Kit import is unchanged (`../dir-pills/kit.mjs`). No strip shape is hard-coded.
- Rule: after the stars are placed and the cut edges restored, move whole units (a loose note, a note with its pill block, a frame with its members) to shorten the board's weighted link length. Every edge between two units counts by its weight: a drawn arrow at 1, an edge cut into a pill at 0.6.
- Candidates: the 24 spots right up against each of the unit's three heaviest neighbours (beside it, above or below, flush or centred), plus four steps toward the weighted middle of its links. A frame goes through the same rule, so it moves toward the notes it links to most (theme 2, in part).
- A move is taken only when the weighted length drops by more than 2% and that gain beats the growth in board size. Size here is MU x total weight x sqrt(area) x (1 + 0.5 x |ln(aspect/1.5)|), so a move that brings the shape closer to 1.5 is rewarded (theme 3, in part). The spot must also be free of every other footprint plus GAP.
- Each move is put together with `assemble` and taken only if `kit.evaluate` says the board is clean and `overlaps` is all zero. Deterministic: units go from the longest weighted length down, and candidates are sorted by gain and then by position. The budget is 80 assembles per board and 2 passes. A throw inside pull keeps the layout as it was before pull.
- `fromdrawing.mjs`: lets look.mjs make pictures from a finished build's drawing.json (`DRAWING=...`), without laying the boards out again.

## Numbers (6 boards, build t1; first version: budget 400, 3 passes)
| board | stars4 size, longest, mean | stars5 size, longest, mean | moves |
|---|---|---|---|
| Validation (bad) | 3546x3871, 5322, 310 | 5327x3149, 2675, 207 | 2 |
| Mentions (bad) | 4517x5124, 3199, 134 | 4881x4970, 3199, 115 | 14 |
| Draw (bad) | 5243x4193, 2803, 276 | 5151x3883, 2803, 250 | 3 |
| TableOfContents | 3750x2139, 1217, 158 | 3750x2139, 1217, 142 | 1 |
| Types/Checks | 2810x1094, 631, 173 | 2820x1094, 631, 150 | 0 |
| FuzzyMatching | 1581x298, 57, 57 | same | 0 |
verify.mjs on t1: 6 of 6 clean, overlaps all zero. Pill counts are higher than in stars4's run even on boards with no move. The kit in dir-pills changed after that run, so the counts are not a like-for-like comparison. table.mjs output: table.txt.

## NOT DONE
- The full build was started at 12:41 and stopped at 13:11, unfinished. The machine's load was 25 to 77 from other builds, and pull adds up to 80 assemble-and-evaluate runs per configuration. So no 71-board numbers, no full verify, and no pictures of the 23 other bad boards.
- Before this module is used, it must have one full build and a verify pass.
- If a full build is too slow, run pull only on the winning configuration, in the main thread: about one eighth of the CPU.
- Theme 4 (hubs ringed by weight) has no rule of its own. Theme 3 has nothing beyond the size term: loose rows are not wrapped. Theme 2 has only the heaviest-neighbour pull, not "the free side of the heaviest notes, within a note's width".

## The 26 bad boards
- Validation: the 2765-long ValidationQueriesPlugin line is gone (longest arrow 5322 to 2675), the board is wider (aspect about 1.7), mean arrow length 310 to 207. Pictures: out/Validation-stars5*.png.
- Mentions: mean arrow length 134 to 115. The longest arrow is still 3199: the MentionsPlugin to MentionLayouts pair did not move. Pictures: out/Mentions-stars5*.png.
- Draw: board 5243x4193 to 5151x3883, mean arrow length 276 to 250. The longest arrow is still 2803 (Draw.swift to DrawPoints.swift). Pictures: out/Draw-stars5*.png.
- CanvasEditor, StickyNotes, TypesIsA, Adornments, LanguageRules, References, Subboards, Types, CanvasPlugins, Queries, Selection, TypesSync, Arrows, Publishing, Reordering, TypesRows, TypesForm, Boards, JumpTo, SlashCommands, Titles, TypesFields, TypesType: not built with stars5 (the full build did not finish).
