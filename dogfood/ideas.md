# Ideas and opportunities

From drawing this codebase onto a board with `canvas draw`.

1. **Let many arrows share one pill.** Each cross-board edge makes its own pill beside where it starts, so 30 files that use `CanvasEditor` get 30 pills. This model needs about 2,400. An edge could reuse a direct reference to the same shape that's already on the board.
2. **A later run's pill could join the column already there.** Today it's pushed into a second column, with a warning.
3. **Make a board file from the CLI.** A script can't start one, so the user has to create and open it first.
5. **Let an agent check its layout.** Queries don't return positions and there's no picture of the board, so a layout of thousands of shapes is drawn blind, and the only check is the result's `at` boxes. A `canvas render` to PNG, or positions in query rows, would close the loop. (I rendered offscreen from a throwaway test.)
7. **Document how to place a shape at an exact offset.** `right of "F" left (gap: x) below "F" top (gap: y)` puts a shape exactly x and y in from F's top-left. The skill doesn't mention it, and the obvious `inside "F" top-left (gap: n)` applies n on every side. A layout computed outside the app needs this.
8. **A width-only size for notes** (`size: 300x`), with the height fitted to the text. Today a note at a custom width with a fitted height takes two runs: draw it with a size, then change its text.
9. **`canvas boards` counts only the shown board's shapes:** 306, for a file of about 2,600. It could give both counts.
10. **Code: 26 files import a module they don't use.** The compiler's index finds no reference to it, implicit ones included; for example, `ArrowLabel.swift` imports Canvas and `JumpTo.swift` imports Boards. The audit compares imports per module, so a dead import in one file passes it.
11. **Put an edge's reference in a frame, or a frame around shapes.** An empty frame is a wall to a pill landing in it, and a frame drawn over pills is pushed off them. Grouping pills in frames takes spacer edges between groups, then frames drawn with `overlap: allow` (which take in what they cover), then deleting the spacers. `frame "X" around …`, as Create Frame does, would make it one step.
12. **Frames need unique titles to be labeled,** so grouping frames are titled "Canvas (QueryTranslator.swift)", hundreds of them, all in Jump To. An untitled frame says only "Frame".
13. **Stack an edge's references closer: 16 apart, not 64.** The list step of 64 leaves room for a title pill above each shape, and a reference has none, so a column of 15 is twice as tall as it needs to be, and its fan steep. The solver marks stand-ins `implied`, so a list made only of them could take a tighter step (`Solver.findLists`, `LayoutProblem.listStep`, `DrawStandIns`). An edge takes no `gap:`, so a script can't do it directly; the generator does it in six runs a board, moving each pill in a temporary frame.
