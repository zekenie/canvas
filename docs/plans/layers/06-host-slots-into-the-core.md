# 06 · The host slots are the core's points, so they move into the core

**Commit title:** The host slots are the core's, so the core declares them: HostSlots folds into Canvas, which takes SwiftUI for their views and the wire for the commands

**Depends on:** 01 (the charter's module rule, which this applies). Independent of 02–05 and 07, and can land in any order after 01.

**Confidence:** moderate. It's a module-granularity call, not a layering defect, and skipping it leaves every other plan intact. The build-cost objection turns out to be almost entirely moot (see the closure numbers below). What's left against it is whether the core should name SwiftUI and the wire's types at all.

## Complaint

"`InfiniteCanvas` depends on `HostSlots`, which is small and feels like it should perhaps be merged with `Canvas`. Spot checked most of the direct dependants of `HostSlots` and they all also depend on `Canvas`."

## Justification

**The spot check doesn't tell either way.** HostSlots' API is extensions on Canvas's `Registry` and `PluginRegistrar`, and the audit requires declaring every module a file imports. So every user of HostSlots necessarily declares Canvas too. The question is what each side of the split is for.

**For merging:**

- **Its points say they are the core's.** All seven declare `owner: .core` (e.g. `Sources/HostSlots/HostSlots.swift:29`), which is how the registry marks a point as always installed. They're the same sort of thing as the fifteen points in `Sources/Canvas/Plugins/CorePoints.swift` (and two in `PropertyTable.swift`) (`Overlays`, `Commands`, `KeyStrokes`, `SecondaryClickMenu`, …), split off by which framework their types come from: SwiftUI views and wire types. Someone asking "what can a plugin give the core and its host?" has to read two modules.
- **The core already holds the other half of the host contract.** That's the `@_spi(Host)` API CanvasView calls (input, the cursor, drawing, the delegate). The plugin-facing half (HostSlots) and the window-facing half (`@_spi(Host)`) sit in different modules for no reason of their own.
- **Nothing needs one side without the other.**
  - Nothing wants HostSlots without Canvas.
  - Nothing gains from Canvas without HostSlots. What the split keeps out of the core, SwiftUI and CanvasRPC, isn't kept out of anything the product runs: the app, Quick Look and the tests of what ships link both.
  - No layer forbids it: foundation may use the wire (`build.sh:29`).
  - **The split barely keeps anything out.** Of the 39 non-test modules over Canvas, 35 already have HostSlots in their closure, and with it its SwiftUI views and the wire's types: Keyboard, which Selection imports, imports HostSlots. It's kept out of only four: SlashCommands, Topology, Snapping and Queries. That drops to three once plan 03 has Queries import Selection. (Measured from `Package.swift`: 30 modules declare Canvas without declaring HostSlots, but most reach it anyway.)
- **It removes two exceptions** the docs have to carry: "the one foundation module that imports SwiftUI" and "the one that imports the wire" (build.md, host-slots.md).
- **The charter's module rule** (plan 01): split a module from another only when something must build without the other, or when a layer forbids an import the merged module would need. Neither holds here.

**Against merging, and what it costs:**

- **`Canvas` would depend on `CanvasRPC`.** CanvasRPC is 1,505 lines with no dependencies of its own, and changed in 2 of the last 50 commits. It's already in 35 of the 39 closures over Canvas; the merge adds the other four. The layer rules still stop any plugin outside the language layer from importing it, and the commands slot's sugar can't be called without naming its types. So, as now, only Automation registers commands.
- **`Canvas` would import SwiftUI**, in the one moved file. The canvas itself stays AppKit. The core gains view-typed contributions, as it already has `NSView`-typed host API.
- **A change to the host slots' interface would recompile every module over Canvas.** build.sh rebuilds a module when the `.swiftmodule` of anything in its closure changes, not just its direct dependencies' (`build.sh:684-685`). So such a change already rebuilds 35 of the 39, and the merge adds four. HostSlots changed in 2 of the last 50 commits.
- **The alternative:** keep HostSlots and write its reason down ("the core's points that hold SwiftUI views or the wire's types, kept out of the core so the core is AppKit-and-model and wire-free"). That's coherent. It's rejected here only because nothing in the product relies on the core being free of either. If being free of them is a goal, take this alternative instead, as a docs-only change.

## Tactics

1. **Move** `Sources/HostSlots/HostSlots.swift` → `Sources/Canvas/Plugins/HostSlots.swift`, beside `CorePoints.swift`. Drop its `import Canvas`. Keep `import CanvasRPC`, `import SwiftUI` and `import CoreGraphics`. Delete `Sources/HostSlots`.
2. **`Package.swift`:**
   - Canvas becomes `dependencies: ["CanvasRPC", "Geometry"]`.
   - Remove `"HostSlots"` from CanvasUI, Keyboard, DetailPanel, LanguageModels, Boards, Automation, StickyNotes, JumpTo and InfiniteCanvas, and from every test target that lists it: AutomationTests, BenchmarkTests, BoardsTests, CanvasUITests, CompositionTests, DetailPanelTests, JumpToTests, KeyboardTests, LanguageModelsTests and StickyNotesTests.
   - Delete the HostSlots target and the comment above it.
   - Rewrite the foundation row of the header.
3. **Sources:** delete `import HostSlots` wherever it appears: Automation 1, Boards 1, CanvasUI 6, DetailPanel 1, InfiniteCanvas 1, JumpTo 1, Keyboard 1, LanguageModels 1, StickyNotes 1, and the test files listed above (CompositionTests has 12). These modules already import Canvas, so the API stays in scope.
4. **Tests:**
   - Move `Tests/HostSlotsTests/HostSlotsTests.swift` (207 lines with main) into `Tests/CanvasTests/HostSlotsTests.swift`.
   - Add `hostSlotsTests` to `Tests/CanvasTests/main.swift`'s `runTests` list.
   - CanvasTests adds `"CanvasRPC"` to its dependencies (it's in Canvas's closure now).
   - Delete the HostSlotsTests target.
5. **`build.sh`:** no change. It names no module, and the audit's "public type named like a module" check is satisfied, since no type is called `HostSlots`.
6. **Docs:**
   - `.claude/rules/host-slots.md`:
     - its `paths:` frontmatter: `Sources/Canvas/Plugins/HostSlots.swift` and `Tests/CanvasTests/HostSlotsTests.swift`, in place of the two directories;
     - "Why it exists": the slots are the core's points, declared in the core, which imports SwiftUI and the wire for them;
     - "Adding a slot";
     - the Testing bullet (HostSlotsTests → CanvasTests' suite).

     It still loads for the right files, since the frontmatter names them.
   - `.claude/rules/build.md`, "Layers": the foundation list and the HostSlots parenthesis.
   - `docs/plugin-system.md`:
     - "Host slots" (`:2667`, the source path, and `:2725`, its tests);
     - the module-graph table's foundation row (`:511`), and `:8929`;
     - "Horizontal and vertical" wherever it lists the foundation.
   - `CLAUDE.md`, two spots in the module-graph rule:
     - "Every plugin may use the foundation (Geometry, Canvas, HostSlots, …)" drops HostSlots;
     - "what a host takes of a plugin's goes through host slots" stays, since the concept keeps its name.
   - No other topic file names the module: they say "host slot" and link host-slots.md, which keeps its name. The module's name appears in `build.md:43`, host-slots.md, and `docs/plugin-system.md` at `:511` (the module table), `:2667` ("Host slots"' source path), `:2725` (HostSlotsTests) and `:8929`. `grep -rn HostSlots .claude docs CLAUDE.md` should come back empty but for the concept's name.

## Verification

- `./build.sh audit`: the import check proves no module still imports HostSlots, and that Canvas's new dependencies are used.
- `./test.sh`, in full, since every module recompiles.
- `./build.sh && open build/InfiniteCanvas.app`: the path, the palette, the inspector, the subtitle, Settings' Anthropic pane, tool tips, the welcome board and `build/canvas help` all work. These are CompositionTests' ShippedTests' seven, held headless too.
- `./build.sh bench`: no budget moves. This is a check, not an expectation of change.

## Risks and open questions

- **Build time:** one more file in Canvas, and CanvasRPC in every closure. build.sh only rebuilds on interface change, so expect no measurable difference. Compare a clean `./build.sh` before and after to confirm.

## Not in this commit

- The app layer and `InfiniteCanvas` stay as they are; see the index, under "Considered and not planned".
