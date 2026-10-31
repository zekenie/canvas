# Walking issues: the build plan

Eight landings, each finished, tested and committed before the next. Landings 1 to 4 build what the walk needs (Find stays green); 5 to 8 build the walk.

## Where the plans differed, decided

- **Walker API.** The walk plan's pull source (`ShapeWalkSource`, rows with a stop count) wins. A Find row is one shape with N hits (`FindState.swift:377-391`), and pushing stops would copy every hit. Validation's rows have 1 stop, or 0 once ignored or holding.
- **Order.** Find's order moves into Topology, with an O(depth) key. Validation can't import Find, and it can't import Boards either, because Boards imports Validation (`Package.swift:301`).
- **List.** The issue list is `DetailRowList` (`ListRows.swift:283`), the panel's existing one-Tab-stop list (P2). No `DetailWalkList`. Find keeps its row window (`FindPanel.swift:166-210`), because its field holds the keyboard.
- **Evidence.** DetailPanel gets `DetailTabView`, lifted from `ShapePanel` (`DetailPanelView.swift:384-410`), which then uses it too. Validation draws `IssuesTab` through it and never names LanguageRules.
- **Light.** Validation draws the light through the core's tinted outlines (`registrar.outlines`, as `LanguageRulesPlugin.swift:54` does). `RulesStyle.light` (`RulesStyle.swift:108`) becomes `IssueWalkStyle.light`, so there is one cyan. The two lights never show at once.
- **Menus.** All the walk's items go in Go, in an `IssuesSection` placed `.after(NavigationSection.self)` (`Selection.swift:44`): Next Issue, Previous Issue, Issue List, Ignore Issue and End Issue Walk.
  - Ignore Issue leaves the Shape menu, because that menu's keys aren't live (keyboard.md) and ⌥⌘' must work from the list.
  - End Issue Walk (no key) is new: with Keyboard navigation off, Done drops out of Tab (P2).
- **⇧⌘'** is `KeyChord("\"", .command)`, the ⌘? convention (`KeyChord.swift:72-80`).
- **Hiding the inspector** ends the walk, as with Find.

## Landing 1: board order in Topology

- `FindSearch.order(of:topology:file:)` (`FindSearch.swift:133`) moves to `TopologySnapshot.boardOrder(from:)`. Find calls it at `:105`.
- New `BoardOrderKey: Comparable` and `snapshot.boardOrderKey(of:)`: each owner's `fileOrderKey` (`TopologySnapshot.swift:136`), then the shape's own. O(depth).
- **Tests.** TopologyTests' Snapshots suite holds that the key sorts as `boardOrder` visits, over its seeded run.
- **Docs.** topology.md, find.md.

## Landing 2: board headings into DetailPanel

The walk plan's landing 1, checked against the code: `FindHeadings` is at `Find.swift:214-246`, and `BoardFindPlugin` at `Boards/BoardHeadings.swift:34-42` is Boards' only `import Find`.

- New `DetailPanel/BoardHeadings.swift`, with `editor.boardHeading(of:)`.
- `BoardHeadingsPlugin` (`board-headings`) is listed beside `BoardContentsPlugin` (`:145`), and `BoardFindPlugin` leaves `:149`.
- **Tests.** A new DetailPanelTests suite, `boardHeadingTests`. These follow the rename: BoardsTests' `HeadingTests`, FindTests' heading tests, CompositionTests' `findShippedTests` and `InspectorTests`, and `shippedTests`' report.
- **Docs.** find.md, detail-panel.md, boards.md, and the guide's §Find and §Boards.

## Landing 3: `ShapeWalk` in Selection; Find its first client

```swift
public struct WalkRow { key: AnyHashable; shape: ShapeID; board: BoardID; stops: Int }
@MainActor public protocol ShapeWalkSource: AnyObject {   // rows, total, stops before a row, focus rect, didMove
@MainActor @Observable public final class ShapeWalk {    // init(editor:arrival: .shows/.selects)
    current: WalkPosition?, stepCount, number; begin(at:), step(forward:), move(by:), moveBoard(by:), pick(row:),
    rowsDidChange(keeping:), boardRuns(), finish(), end()
```

- **Where it lives.** `Sources/Selection/Walking.swift`. Selection imports nothing new.
- **Moving.**
  - Each move runs inside `editor.navigate(from:)` (`GoingTo.swift:152`) from `navigationStart` (`:143`), so the whole walk is one Back step.
  - `.shows` is Find's `go(to:)` (`FindState.swift:478-490`), moved.
  - `.selects` is `goTo` (`GoingTo.swift:111`: it reveals only when the shape isn't readably in view), then `revealIfOffscreen(rect:)` (`:86`, internal, same module) for a focus rect.
  - `step` passes over rows with no stops; `move` reaches them.
- **Find.** It forwards `current`, `currentNumber`, `step`, `select`, `move`, `finish` and `stepCount` with their signatures and guards unchanged (`FindState.swift:363-437`). Search, landing, `pendingStep` and labels stay Find's.
- **Tests.**
  - SelectionTests `walkTests`: wrapping, ordinals, empty rows, boards, both arrivals, the camera, one Back step, Forward, inserted rows, `finish`, a gesture under way.
  - FindTests unchanged.
  - `./build.sh bench`.
- **Docs.** selection.md ("Walking shapes"), find.md, and the guide after §Moving between shapes.

## Landing 4: the panel's pieces (DetailPanel; no new imports)

- **Bands.** `DetailBands`, in `DetailOverview.swift`: `registrar.detailBand(isActive:onCancel:)`, where the first active band shows.
  - The band sits above the takeover, the overview or the header (`DetailPanelView.swift:50`).
  - It is first in the ring.
  - It keeps the inspector requested (`DetailPanelPlugin.swift:24`); hiding the inspector runs `onCancel`.
- **Escape and ⌘. split** (`DetailPanelView.swift:115-128`).
  - Escape runs the takeover's `onEscape`, then `focusBand()` if a band is active, else `onExit`.
  - ⌘. runs `onEscape`, then the band's `onCancel`, then `onExit`.
  - `DetailPanelState.keyboardPlace` is one of `.band`, `.takeover` or `.content`.
- **`DetailTabView(editor:shape:tab:)`** draws one tab's lines and sections.
- **`DetailRowList`** gains:
  - `highlight: Binding<ID?>?`;
  - `pages: ((Bool) -> ID?)?`, Page Up and Page Down taken in `ListAnchor` as it takes Home and End (`ListRows.swift:363-381`).
- **Tests.**
  - `TakeoverTests` gets a `BandPlugin`: placement, two bands, the report, no owner, the Escape ladder, ⌘., `keyboardPlace`, hiding.
  - `PanelWalkTests`: the band in the ring forward and back, and the `Walker` list's binding and pages.
  - ListRowTests unchanged.
- **Docs.** detail-panel.md, host-slots.md, keyboard-navigation.md, and the guide's §The overview and takeovers.

## Landing 5: where an issue comes from

- **Validation.**
  - `ValidationIssue.source: IssueSource?` (`Validation.swift:22`), where `IssueSource(plugin: PluginID, key: String)`.
  - `IssueAction.role` (`.ignore`, `:57`). Equality stays by title (`:66`).
- **LanguageRules.** Its warnings (`RuleChecks.swift:286`) carry their `RuleKey` (`:28`), and their Ignore carries the `.ignore` role.
- **Tests.** ValidationTests `issuesTabTests`, through `validationIssues(of:in:editor:)` (`:556`), and LanguageRulesTests `ruleChecksTests`.
- **Docs.** validation.md, language-rules.md.

## Landing 6: `IssueWalk`, scopes, the Go items

New files `Validation/IssueWalk.swift`, `IssueScopes.swift` and `IssueWalkStyle.swift`, in `IssueWalkPlugin`, listed after `ValidationDetailsPlugin` (`Package.swift:158`).

```swift
public struct IssueScope { id; includes: (ValidationIssue) -> Bool; label: (CanvasEditor) -> IssueScopeLabel?; candidates: ((CanvasEditor) -> Set<ShapeID>)? }
public enum IssueScopes: ExtensionPoint {}   // registrar.issueScopes { source, editor in IssueScope? }
@Observable public final class IssueWalk: EditorService, ShapeWalkSource {   // editor.issueWalk
    scope, rows, isListOpen; begin(_:at:forward:), step(forward:), ignoreCurrent(), end(), place(of:source:), scopeDidChange(from:to:)
```

- **Stops.** Issues that show (`Validation.swift:19`) and that the scope includes. Incomplete issues and unsure answers are never stops.
  - They are gathered from the scope's `candidates`, else from `queries.run(":invalid, :warned", settle: nil)`, read as `ValidationQueries.swift:58-79` reads them.
  - They are sorted by `boardOrderKey`.
- **Updates.** `documentDidSettle` and `recheck` (`Validation.swift:406`) hand over ids, which join through `rowsDidChange(keeping:)`.
- **A gone issue** keeps its row: "ignored" if the last action on it had role `.ignore`, else "holds".
- **A reworded rule.** `RuleWriter` calls `scopeDidChange`, and the walk follows the rule in place.
- **Arriving at a stop.**
  - The Issues tab is chosen (as `RuleWriter.swift:96` does); `editor.announce` (`Canvas/Editor/Accessibility.swift:265`) speaks it.
  - Names come from `registry.title(of:)` (`Titles.swift:368`), and an arrow is named by its ends' carried edge, as `RuleChips.swift:315` does.
- **Commands.**
  - `.nextIssue` (⌘') and `.previousIssue` (⌘") repeat and run `.betweenPresses`.
  - `.ignoreIssue` (⌥⌘') is enabled on a live stop with an `.ignore` action.
  - `.endIssueWalk` has no key.
- **LanguageRules.** `RuleValidationPlugin` adds `issueScopes`: its candidates are `flagged(by:)` (`RuleChecks.swift:239`), and its label is "Rule n" with the type's chip.
- **Tests.**
  - ValidationTests `issueWalkTests`: order across pockets, wrap, ⌘' then ⇧⌘', one Back step, Ignore, "holds", undo, a `recheck` arrival off the board shown, announcements.
  - LanguageRulesTests `ruleWalkTests`: the scope, unsure answers, Ignore as one step, and a reword.
  - KeyboardTests: ⇧⌘' reaches ⌘".
  - CompositionTests: `keyboardShortcutsShippedTests`, BoardDocumentTests (the Go items' rows, titles and keys), `languageRulesShippedTests` (the shipped product's walk, including ⌘' beginning All Issues); `keyMeaningsShippedTests` and `reachCensusTests` need nothing until the band and the list (landings 7 and 8), the Go items being menu-bar commands with keys and no surface of their own. Benchmarks: `issueWalkGather10k`, `issueWalkStep`.
- **Docs.** validation.md, keyboard.md, language-rules.md, benchmarks.md, and the guide after "A tab of status lines".

## Landing 7: band, count, "9 of 63", light

`IssueWalkPanelPlugin` is listed after `IssueWalkPlugin`.

- **The band.** The chip and "Rule 1", or "All Issues"; then ‹ "12 of 63" › and Done.
  - The count (a click, or Return) opens the list; Done, or ⌘. in the band, ends the walk; Escape goes to the canvas.
- **"9 of 63".** A `DetailStatusAction` added in `IssuesTab.swift:14-23` to lines whose scope has candidates.
  - It is cached per scope against the flagged set.
  - It is not shown on the walk's own line.
  - That line's Ignore tells the walk.
- **FlagCount** (`RulesPanel.swift:121-133`). A click, or Return, begins the rule's walk. The lighting stays as it is.
- **The light.** The walk's other live stops on the board shown, while `keyboardPlace` is `.band`, or `.takeover` with the list open.
- **Tests.**
  - ValidationTests `issueBandTests` (adds CanvasUI): a `KeyWalk` with Keyboard navigation on and off, the Escape ladder, Done, the light's pixels, and the line's action.
  - LanguageRulesTests `ruleWindowTests`: the count begins at stop 1, and Select Flagged ▸ still selects.
  - CompositionTests `languageRulesShippedTests`, and the gallery's band.
- **Docs.** validation.md, language-rules.md, detail-panel.md, keyboard-navigation.md.

## Landing 8: the list, Issue List, evidence

- **Issue List** (`.issueList`, ⌃⌘') toggles the list of the walk running, else begins All Issues with the list open.
- **The list** is a `detailTakeover` holding a `DetailRowList`, over `DetailTabView(shape: current, tab: IssuesTab.self)`.
  - Heads are `DetailGroupHeader(isRow: true)` ("Texas 9"), named by `boardHeading(of:)`. All are folded but the current board's.
  - Rows are `DetailShapeRow(dimmed:)`, ending in the row's first value.
- **The first value** comes from a new scoped point in Validation, `IssueRowValues`. Types fills it with `IssueRowValuesPlugin` (a plugin value in the module's own sources, `forShapes(holding: FieldValuesProperty.self)`), from `RowBook.findTexts(of:)` and `findTexts(ofRelationship:)` (`Types/Engines/FieldFind.swift:87,105`).
- **Keys.**
  - ↑ ↓ walk the lines, heads too, as in every `DetailRowList` (P6).
  - Page Up and Page Down move by board.
  - ← → fold.
  - Return on a row closes the list there and puts the keyboard in the shape's panel (P5).
  - Escape goes to the band.
  - Opening the list ends editing.
- **Tests.**
  - ValidationTests `issueListTests`: order, folds, a dimmed "ignored" row, Return, Escape, the ⌃⌘' toggle, and a `KeyWalk`.
  - `KeyMeanings` gets an "issue list" row, with Page Up and Page Down as a named exception: pages by board.
  - CompositionTests: LanguageRules' Rules and Shown in the evidence, and the gallery's list.
  - TypesTests: the value.
- **Docs.** validation.md, types.md, keyboard-navigation.md, and the CLAUDE.md map.

## The module graph

- **Boards.** Gains DetailPanel, loses Find (`:301`); no cycle, as DetailPanel (`:286`) reaches no Boards.
- **Validation.** Gains Selection, Keyboard, Topology and Titles (`:294`); none reaches Validation (Titles' closure, `:295`, has none).
- **ValidationTests.** Gains Selection, Topology, Keyboard, Titles and CanvasUI.
- **BoardsTests.** Loses Find.
- **Topology, Selection, DetailPanel, Find, LanguageRules, Types.** Unchanged.
- **Shipped list.**
  - `BoardFindPlugin` becomes `BoardHeadingsPlugin`.
  - The two `IssueWalk` plugins go after `ValidationDetailsPlugin`.
  - `Types.IssueRowValuesPlugin` goes after `TypeDetailsPlugin`.

## Risks

- **Find's stepping** is shipped code: its forwarding API, unchanged tests and the bench guard it.
- **All Issues on the House board** (14,547 shapes) runs rules on the main actor; benchmarks hold it.
- **"9 of 63"** is asked each commit, so it is cached.
- **`DetailRowList`** rebuilds its items in O(rows).
- **Ignore Issue in Go** moves one item of the design.

## Questions for the owner

1. **An ignored current stop:** "12 of 62" (the next ⌘' reads 12 too) or "– of 62"? I recommend "– of 62".
2. **A rule's walk with Keyboard navigation off:** the count and "9 of 63" leave Tab, and P2 wants a menu way while Select Flagged ▸ still selects. Add Shape › Walk Flagged ▸? I recommend yes.

## After merging main (2026-10-30): what changes, by landing

The branch merged main (30707e20: boards of 100,000 shapes, /bulk-create's shapes placed later, signing in through Claude Code). A re-check of every citation found nothing that changes the approved design (`approved-design.md`); these are the decisions it needed. Cite by symbol as well as line: lines drift.

- **Landing 1.** Find's order is not `fileOrderKey`'s: Find lists a board's own shapes (a frame's contents right after the frame) before any board under it, and `forEachShape(inFileOrder:)` puts an owner's board right after the owner (root [A owns a board holding x, B]: Find A, B, x; fileOrderKey x=[0,0] < B=[1]). So `BoardOrderKey` is a chain of per-board segments (each owner's place on the board above, then the shape's own in-board segment, its container chain as `fileOrderKey` builds it), compared segment by segment, a shorter chain that is a prefix of the other first (a board's own shapes before the boards under it). Build it in one climb in `Containment` beside `fileOrderKey` (Containment.swift:141), O(depth), with its guards and nil for a board the app can't show. `boardOrder(from:)` takes a scope board and returns `[ShapeID]`; the key is the root's, and sorting by it gives the same relative order inside any scope. Find keeps its own file-only fallback for no Topology (FindSearch.swift:143, :148). Tests: beside the seeded run's fileOrderKey check (SnapshotTests.swift:155-158), every shape sorted by key equals `boardOrder(from: .root)` and an unshowable board's shape has none; a hand-built A/x/B case; picks from `h.file[board].shapes` wrapped in `Array(...)` (main's pattern). Find's tests stepping across boards must include a board with shapes after an owner of a populated board.
- **Landing 2.** `BoardFindPlugin` is at Boards/BoardHeadings.swift:32-39. `editor.boardHeading(of:)` returns the contributor's heading, else "Board" for the root and "" otherwise, the constant in DetailPanel's style enum (Find's `FindStyle.rootHeading` goes). Also: BenchmarkTests' FindBenchmarks.swift:47 names `.boardFind`; tests that ship the new plugin install `DetailPanelPlugin` (BoardsTests' plugins, InspectorTests.swift:357-366); the golden report line moves after `board-contents`; docs build.md (its plugin list), boards.md (:22, :53), find.md (:32), detail-panel.md (its list of points), and the guide (:313, :479, :8246, :9554).
- **Landing 3.** Every walker move guards `editor.session == nil` and refuses while shapes wait to be placed (`editor.isPlacingLater`, CanvasEditor.swift:1375): a step neither drops nor moves them. "The first stop after the selection" with several shapes selected (a placement selects them all) is after the last of them in walk order. `.selects` never assumes `goTo` selected: a stop whose shape can't be selected, or whose board can't be shown, is still the current stop and the walk moves past it. `finish()` keeps Find's order (read the hit, end, then navigate from the walk's start), and every move navigates from the start captured at `begin`, never a new one, so ⌘[ goes back to where the walk began. `rowsDidChange(keeping:)` is Find's remap (FindState.swift ~335-348). `stepCount` counts every move, pick and step, as Find's does.
- **Landing 4.** `DetailBands` beside `DetailTakeovers` (DetailOverview.swift:46-53, sugar ~:92-98, `activeDetailBand(in:)`); the band's view placed once in init as `PlacedTakeover` is; the body wrapped in a `VStack` with the band above, the modifiers moved onto it. `exitByKey(withOption:)` (DetailPanelView.swift:118-129) splits Escape (the takeover's `onEscape`, then `focusBand()` while a band is active, else `onExit`; from inside the band, Escape goes to the canvas) from ⌘. (the takeover's `onEscape`, the band's `onCancel`, `onExit`). `isRequested` is a takeover or a band; `onDismiss` cancels the band too. `keyboardPlace` and `focusBand()` sit by `keyboardEntry` (DetailPanelState.swift:233). `DetailTabView` is ShapePanel's `if let current` scroll block (DetailPanelView.swift ~:386-409), ShapePanel keeping its header, tab strip, footer and `contentChanged()`. `DetailRowList` takes `highlight: Binding<ID?>?` (focus-independent: an external binding is never written nil as focus leaves or a row folds away) and `pages: ((Bool) -> ID?)?` (keys 116, 121 in `move`, and in `ListAnchor`'s key equivalents; nil keeps the table's own paging). The Tab ring closes again as the band appears or goes.
- **Landing 5.** `IssueSource` is `Hashable, Sendable`; `.error`, `.warning` and the init default it to nil. LanguageRules' warnings take `IssueSource(plugin: RuleValidationPlugin.id, key:)` from the same `RuleKey` `refreshFlags` builds; the unreadable-chip warnings carry none. A sourceless issue is a stop by (shape, field, path, message). The suites are ValidationTests' `validationDetailsTests` and LanguageRulesTests' `ruleCheckTests`.
- **Landing 6.** Gather with `queries.matches([QueryMatchRequest(":invalid, :warned")])` (ids in file order, no rows, no cap now), then read each id's issues: the engine's `cachedResult(for:)` while it's current on the board shown, else `registry.validationIssues(of:in:editor:)` with one `ShapeContext` a board, under `withoutObservingDocument`. A stop is (shape, source) or the sourceless key, so a shape with two issues is two stops. ValidationEngine tells the walk what `recheck`, `recheckWords` and `askRules` changed before `mark` drops off-board ids, as a set, with no per-id lookup. Arriving chooses the Issues tab for the stop's kind (`DetailPanelState.choose(.of(IssuesTab.self), for:)`, as RuleWriter.swift:97 does) and Done gives each kind its tab back. Names: `registry.title(of:)`, an arrow by its carried edge's ends (`edges(carriedBy:)`, slot ""), else the kind's label; named lazily. The light follows `RuleLights` (one stable `Outlines`, `setNeedsDisplay` only on change, one array a group kept from frame to frame, built from rows that carry their board). A reworded rule is followed from the type's schema change in the walk's own `documentDidSettle` (undo and redo of a reword, an edit in the Schema tab, a rule deleted), not from `RuleWriter` alone. The Go items' section goes `.after(NavigationSection.self)`; check where it lands beside Boards' `PathSection` in the shipped menu test. Chords: ⌘' `KeyChord("'", .command)`, ⇧⌘' `KeyChord("\"", .command)`, ⌥⌘' `KeyChord("'", [.command, .option])`, ⌃⌘' `KeyChord("'", [.command, .control])`. Next and Previous Issue don't run while shapes wait to be placed. `EditorService.didPlace` is `didPlace(_ ids: [ShapeID], in:)` now; conform in an extension.
- **Landing 7.** `FlagCount` is RulesPanel.swift:121-147; its click and Return begin the walk, its hover lighting stays, and its comment and language-rules.md's text about the count are rewritten. "9 of 63"'s title carries the place and the count (a `DetailStatus` is equal by its actions' titles), and its closure reads the live walk by scope and shape.
- **Landing 8.** Page Up and Page Down by board is a named exception in keyboard-navigation.md's P6 table, `KeyMeanings` (a meaning, a canonical row, its `allows` case, the exception) and a `KeySurface` for the list in `keyMeaningsShippedTests`. The list's rows follow Neighbors' (`NeighborDetails.swift:98-125`: heads and rows built by the caller, an equatable row view), every board but the current one folded so only its rows are built; a row's first value is `DetailShapeRow`'s `detail:`. Return on a row closes the takeover through its `onExit` and puts the keyboard in the shape's panel. The census reaches the band, "9 of 63" and the list.
