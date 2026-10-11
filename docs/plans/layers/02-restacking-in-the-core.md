# 02 · Restacking belongs to the core; Reordering is only the Arrange menu

**Commit title:** Bring Forward and Send Backward are the core's, as Bring to Front and Send to Back are; Reordering is the Arrange menu over them

**Depends on:** 01, for the word "feature" in the docs this touches. The code has no dependency on it.

## Complaint

Reordering "feels like maybe it should not be in a vertical. Question if it even should be its own module. Maybe it's part of `Canvas`?"

## Justification

- **The core already owns paint order.** Paint order is each record's `stackingKey`, and `editor.paintOrder(in:)` is the per-frame read.
- **Four of the six restacking operations are already in `Transaction`:**
  - `bringToFront` (`Sources/Canvas/Model/Transaction.swift:345`);
  - `sendToBack` (`:360`);
  - `move(_:above:)` (`:371`);
  - `move(_:below:)` (`:384`);
  - on-board variants at `:903` and `:911`.

  All of them already take containers' contents along and refuse read-only shapes.
- **Two pieces of real behavior live in a plugin instead:**
  - tldraw's Bring Forward and Send Backward, "step just past the nearest overlapping shape that isn't moving, isn't held in it, and isn't painted by anchor" (`Examples/Reordering/Reordering.swift:46-72`);
  - keeping several shapes' order among themselves (`backToFront`, `:42-44`).

  Both use only the core's API: the document, the registry's `containingKinds`, `PaintOrderAnchored`, and geometry. A `Transaction` already holds `registry` (`Transaction.swift:56`) and lends geometry through `shapes` (`:128`).
- **So the restacking rules are split across two modules.** A future caller would have to copy the step logic: the command line restacking a shape, a keyboard shortcut, or a "send behind" in a container's own menu.
- **What can't move into `Canvas` is the menu.** A context menu is a contribution to ContextMenus, a surface, and the core declares no menus (it only lends `menuForSecondaryClick`, which ContextMenus claims).
- **Why Arrange isn't ContextMenus' own built-in item, the way Delete and Select All are:** those two run Selection's commands, and every list that has ContextMenus has them. Arrange is something a plugin list should be able to leave out (`Package.swift:176`: "one line here; delete it to leave it out"). It's also the guide's worked example of items on every shape, chosen by capability (`docs/plugin-system.md:3515`, "Every shape: Reordering"). So Reordering stays a module, in the feature layer (plan 01), and holds the menu and nothing else.

Where each part should live, then:

| Part | Lives in | Why |
|---|---|---|
| The six restacking operations, several shapes at once, keeping their order | `Canvas` (`Transaction`) | paint order is the core's; the operations need only the core |
| The Arrange submenu on every shape not painted by anchor | `Reordering` (feature) | a presentation on a surface that a list may leave out |

## Tactics

1. **`Sources/Canvas/Model/Transaction.swift`, under "Restacking"**, add, each documented as its neighbors are:
   - `bringToFront(_ ids: [ShapeID])` and `sendToBack(_ ids: [ShapeID])`: several shapes, keeping their order among themselves. This is `backToFront`'s sort over `document.index(of:)`, then the existing single-shape calls (front: back-to-front order; back: reversed).
   - `bringForward(_ ids: [ShapeID])` and `sendBackward(_ ids: [ShapeID])`: the step routine moved verbatim. It reads bounds from `shapes.geometry(of:)` (the transaction's own context; restacking changes no geometry, so this is what `editor.shapeContext` gave), held shapes from `document.descendants(of:containingKinds: registry.containingKinds)`, and anchors from `registry.definition(for:) is any PaintOrderAnchored`. Then it calls `move(_:above:)` and `move(_:below:)`.
   - Board variants (`on board:`) only if `move(_:above:on:)` callers need them now. They don't today, so leave them out.
2. **`Examples/Reordering/Reordering.swift`**: each `MenuItem` becomes one `editor.transact("…") { $0.bringForward(ids) }`, and so on. `backToFront` and `step` go away, and the file drops to about 30 lines. Drop the now-unused `import CoreGraphics` (it was only there for `CGRect`).
3. **`Package.swift`**: nothing (Reordering's dependencies stay Canvas and ContextMenus).
4. **Tests**:
   - Move the ordering cases from `Tests/ExamplesTests` (a step past an overlapping shape, nothing to pass, several shapes keeping their order, a container's contents going along, an anchored kind not counted) into CanvasTests. They belong beside `restackingOnBoardsTests` as a new `restackingTests` suite over CanvasTesting's boxes. Add the suite to `Tests/CanvasTests/main.swift`'s `runTests` list (test.sh fails a declared suite left out).
   - ExamplesTests keep what is the plugin's: the submenu's outline, which kinds get it (`PaintOrderAnchored` left out), and that each item restacks and names its undo step ("Bring Forward").
5. **Docs**:
   - `docs/plugin-system.md`:
     - "Every shape: Reordering" (`:3515`): the example shrinks to the menu over the core's operations. That makes it a better "smallest plugin" (it shows a feature contributing to a surface over core API).
     - Wherever the guide lists the core's restacking: add the two step operations and the several-shape forms.
   - `.claude/rules/containers.md:23`, the restacking bullet, and the guide wherever it names `bringToFront` (`docs/plugin-system.md:3528, :4767, :10556, :11288`): add the new operations.
   - `.claude/rules/context-menus.md`: the Reordering mention stays accurate (still Arrange, still `PaintOrderAnchored`).

## Verification

- `./build.sh audit` passes.
- `./test.sh`. To iterate, run the executables it builds, `build/debug/CanvasTests/CanvasTests` and `build/debug/ExamplesTests/ExamplesTests`. `TEST_FILTER` matches suite and test names ("Suite: test"), not targets, and fails when nothing matches.
- In the app: Arrange on overlapping notes behaves as before, and Undo says "Undo Bring Forward".

## Risks and open questions

- **Behavior has to be identical.** The routine moves unchanged. The only difference is reading geometry from the transaction's context instead of the editor's captured before the transaction. Those agree because nothing in the transaction changes geometry before the step runs. The moved tests are the proof.
- **The name stays Reordering.** Renaming it Arrange would match the menu, but it's churn the complaint didn't ask for.

## Not in this commit

- Keyboard shortcuts (⌘] / ⌘[) or a menu-bar Arrange menu: new behavior, not a move.
- Moving Reordering out of `Examples/`: its place there is about teaching, not layering.
