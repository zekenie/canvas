# Ideas and opportunities

From drawing this codebase onto a board with `canvas draw`.

1. **Let many arrows share one pill.** Each cross-board edge makes its own pill beside where it starts, so 30 files that use `CanvasEditor` get 30 pills. This model needs about 2,400. An edge could reuse a direct reference to the same shape that's already on the board.
5. **Let an agent check its layout.** Queries don't return positions and there's no picture of the board, so a layout of thousands of shapes is drawn blind, and the only check is the result's `at` boxes. A `canvas render` to PNG, or positions in query rows, would close the loop. (I rendered offscreen from a throwaway test.)
11. **Put an edge's reference in a frame, or a frame around shapes.** An empty frame is a wall to a pill landing in it, and a frame drawn over pills is pushed off them. Grouping pills in frames takes spacer edges between groups, then frames drawn with `overlap: allow` (which take in what they cover), then deleting the spacers. `frame "X" around …`, as Create Frame does, would make it one step.
12. **Frames need unique titles to be labeled,** so grouping frames are titled "Canvas (QueryTranslator.swift)", hundreds of them, all in Jump To. An untitled frame says only "Frame".
