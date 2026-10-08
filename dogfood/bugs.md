# Bugs

Found while drawing this codebase onto a board with `canvas draw` (main at 2df3c02c).

6. **Restating a shape `in` a subboard makes a second one.** With "zz-orphans 1" on the root, `frame "zz-orphans 1" in "zz-trash"` dry-runs as `created` on zz-trash's board, two shapes, one title, where a title should mean the shape it names (a move or a refusal).
