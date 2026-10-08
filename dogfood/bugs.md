# Bugs

Found while drawing this codebase onto a board with `canvas draw` (main at 2df3c02c).

1. **A column of pills splits when one pill hits a wall.** Note X has three pills on its right. `sticky-note "G" below "X"` plus six edges from G to public shapes on another board: G's top pill lands on X's bottom pill and is pushed right on its own, while the other five stay. A list should move as one.
2. **A pill column moves without saying so, and a neighbor goes off its line.** Same script plus `sticky-note "H" right of "G"`: G's pills move 132 down with no `pushedPast` and no warning, and H lands at y=446 although G's center is at 834. A push shouldn't take a shape off its centering.
4. **Restated frames are judged where the others are now, not where the run puts them.** One run moving the root's ten bands to new places, none overlapping, is refused: `"Composition layer" and "UI layer" overlap … unordered`; Composition's new box covers UI layer's old one. With overlaps allowed, bands are nudged out of each other's old places. Moving them all aside first, then into place, works.
6. **Restating a shape `in` a subboard makes a second one.** With "zz-orphans 1" on the root, `frame "zz-orphans 1" in "zz-trash"` dry-runs as `created` on zz-trash's board, two shapes, one title, where a title should mean the shape it names (a move or a refusal).
7. **Draw makes frames under the minimum.** `frame "X" size: 160x40` draws a frame 40 tall, though the Frame tool and resizing keep to 96 × 64. (The generator relies on it, for a pill's temporary frame.)
