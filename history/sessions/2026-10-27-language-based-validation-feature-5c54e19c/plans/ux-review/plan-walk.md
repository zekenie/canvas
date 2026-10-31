# Plan: the walker and the panel (walk)

Four landings, each finished, tested and committed before the next. Validation's `IssueWalk` builds on all four. No new modules.

## Landing 1: board headings move down to DetailPanel

Find's `FindHeadings` (`Sources/Find/Find.swift:214-246`) becomes DetailPanel's `BoardHeadings`, in a new `Sources/DetailPanel/BoardHeadings.swift`:

```swift
public struct BoardHeading: Hashable { public var title: String; public var systemImage: String? }
public enum BoardHeadings: KeyedExtensionPoint   // owner .detailPanel, key "heading", summary "board heading"
extension PluginRegistrar { public mutating func boardHeading(_: @escaping @MainActor (BoardID, CanvasEditor) -> BoardHeading) }
extension CanvasEditor { public func boardHeading(of: BoardID) -> BoardHeading }  // else "Board" (root) / ""
```

- `FindStyle.rootHeading` moves to `DetailStyle`.
- `FindState.heading(of:)` (`FindState.swift:120`) forwards to the new reader and still caches the contribution (`:111`).
- Boards' `BoardFindPlugin` (`Sources/Boards/BoardHeadings.swift:34-42`, id `board-find`) becomes `BoardHeadingsPlugin` (id `board-headings`). It is listed after `BoardsPlugin` and `DetailPanelPlugin`, beside `BoardContentsPlugin` (`Package.swift:145,149`).

**Audit.** Boards gives up `Find` and takes `DetailPanel` (`Package.swift:301`). BoardHeadings.swift is Boards' only Find import. BoardsTests drops `Find` if `HeadingTests` was its only user.

**Tests.**
- A new DetailPanelTests suite, `boardHeadingTests`: the report, a conflict, the owner not installed, and the fallbacks.
- Renamed to the new point:
  - BoardsTests `HeadingTests.swift:67-106`
  - FindTests `PanelTests.swift:300-312`
  - CompositionTests `FindShippedTests.swift:293`, `InspectorTests.swift:366`
  - `ShippedTests.swift:157` (the report snapshot)

**Docs.**
- find.md: the panel bullet, and drop `Sources/Boards/BoardHeadings.swift` from its `paths:` (detail-panel.md takes it).
- detail-panel.md and boards.md.
- Guide (`docs/plugin-system.md`): §Find `:8192`, §Boards `:9494`, `:479`, and §The overview and takeovers.

## Landing 2: `ShapeWalk` in Selection, Find its first client

It lives in a new `Sources/Selection/Walking.swift`, since Selection owns going to shapes and Back (`GoingTo.swift:111,143,152`). It needs no new import. "One walker" means one type: each client owns an instance.

```swift
public struct WalkPosition: Hashable, Sendable { public let row: Int; public let ordinal: Int }
public struct WalkRow { public let key: AnyHashable; public let shape: ShapeID; public let board: BoardID; public let stops: Int } // 0: listed, never stepped to
public enum WalkArrival { case shows, selects }
public enum WalkMove { case step(forward: Bool), rows(Int), board(Int), picked, landed, finished }

@MainActor public protocol ShapeWalkSource: AnyObject {
    var walkRowCount: Int { get }
    func walkRow(_ row: Int) -> WalkRow
    var walkTotal: Int { get }
    func walkStops(before row: Int) -> Int
    func walkRow(withKey: AnyHashable) -> Int?            // default: a scan
    func walkFocus(at: WalkPosition) -> CGRect?           // default nil: the shape's bounds
    func walkDidMove(to: WalkPosition, _ move: WalkMove)  // default: nothing
}

@MainActor @Observable public final class ShapeWalk {
    public init(editor: CanvasEditor, arrival: WalkArrival)
    public weak var source: ShapeWalkSource?
    public private(set) var current: WalkPosition?
    public private(set) var stepCount: Int            // +1 per move but `landed`: VoiceOver announces by it
    public var number: Int?                           // nil on a 0-stop row
    public func begin(at: WalkPosition? = nil)        // takes editor.navigationStart
    public func land(on: WalkPosition?, goes: Bool)   // no step counted
    public func step(forward: Bool)                   // stop by stop, rows with stops, wrapping
    public func move(by rows: Int)                    // every row, 0-stop too, wrapping
    public func moveBoard(by: Int)
    public func pick(row: Int)
    public func rowsDidChange(keeping key: AnyHashable?)
    public func boardRuns() -> [(board: BoardID, rows: Range<Int>, stops: Int)]   // lazy, dropped on change
    @discardableResult public func finish(_ before: () -> Void = {}) -> Bool  // goTo current, one Back step
    public func end()
}
```

**Moving.** Every move goes to its stop inside `editor.navigate(from: start)`, so the whole walk is one Back step and ⌘] returns to the last stop.
- `.shows` is Find's `go(to:)` (`FindState.swift:478-490`), unchanged.
- `.selects` is `goTo([shape])`: it selects, at a readable zoom. If a focus rect is still out of view, `revealIfOffscreen(rect:)` (`GoingTo.swift:86`) brings it in, for a long arrow's chip.
- Nothing moves mid-gesture.

**What FindState hands over:** `current`, `stepCount`, `start` (`:75`), the arithmetic of `step`/`select`/`move` (`:376-424`), `finish` (`:431`), `go` (`:478`) and `currentNumber` (`:125`).

**What FindState keeps:** search, index, results, `places`/`offsets`, scope, order, landing and `keep`'s rank fallback (`:302-349`), `pendingStep` and the readiness guards (`:372`), labels, the announcement, symbols and upkeep.

**Find as the source.**
- Rows are the results, keyed by shape id; each row's stops are its `hitCount`.
- `walkStops(before:)` = `offsets[i]`; `walkFocus` = `hitBounds` (`:494`).
- `walkDidMove` clears `labelStems` and redraws.
- `setResults` (`:288`) calls `rowsDidChange`; `open` calls `begin()`, `close` calls `end()`.

**FindTests stay green.** Find's public names forward to the walk: `current` maps to `FindPosition(result: row, ordinal:)`, and `currentNumber`, `stepCount`, `step`, `select`, `move` and `finish` keep their signatures and guards. So FindTests and FindShippedTests are untouched. Both run with `TEST_FILTER=Find`, and the work runs `./build.sh bench`.

**A client that isn't Find:**
- It adopts `ShapeWalkSource`, makes `ShapeWalk(editor:, arrival: .selects)`, sets `source = self` and calls `begin(at:)` with the first stop after the selection, found in its own order.
- When its stops change it calls `rowsDidChange(keeping:)` with the current row's key (an issue's: its shape and `ValidationIssue.source`). Arrivals join in file order and the current stop stays current.
- An ignored issue keeps its row with `stops: 0`: it stays in place, ⌘' passes over it, and `number` is nil while it is current.
- It is told each step synchronously in `walkDidMove(to:_:)` (to choose the Issues tab and set the light). Views observe `current` and `stepCount`, and the announcement posts on `stepCount`.

**Tests.** A new SelectionTests suite, `walkTests`, over `GoToBoardsTests`' `Pocketed` with a fixture source. It holds:
- wrapping and ordinals;
- 0-stop rows: passed over by `step`, reached by `move`;
- `number` across those gaps;
- `moveBoard`;
- both arrivals: the camera staying when in view, revealing otherwise, and the readable zoom;
- one Back step across boards, and Forward;
- a click or pan between steps adding none;
- `land` counting no step;
- rows inserted before the current one, which stays current;
- `finish` and `end`;
- a gesture under way.

**Docs.** selection.md ("Walking shapes" after Going to shapes), find.md (the FindState bullet), and a new guide section after §Moving between shapes (`:2724`).

## Landing 3: the list window, `DetailWalkList`

It lives in a new `Sources/DetailPanel/WalkList.swift` and takes over Find's row window (`FindPanel.swift:166-210`):

```swift
public struct DetailWalkList<Row: View>: View {
    public init(walk: ShapeWalk, folds: Bool, takesKeyboard: Bool, label: String,
                onReturn: @escaping @MainActor () -> Void = {},
                @ViewBuilder row: @escaping (_ row: Int, _ isCurrent: Bool) -> Row)
}
```

**Drawing.**
- It shows `DetailStyle.walkWindow` (200) rows around the current one, with "N more" at each end, and scrolls the current row into view.
- Board heads come from `editor.boardHeading(of:)`.
- With `folds`, a head is a `DetailGroupHeader(isRow: true)` with its stops ("Texas 9", which VoiceOver reads as "Texas, 9, collapsed"). Every board is folded but the current one's, unless the person turned it.
- Without `folds`, heads are Find's as drawn today.

**Keys.** With `takesKeyboard` the list is one Tab stop, an AppKit key view reading `KeyMeaning` (the pattern of `ListAnchor`, `ListRows.swift:406`), so Keyboard navigation off can't drop it.
- ↑ ↓: `move(by:)`, which reaches dimmed rows (P1).
- Page Up, Page Down: `moveBoard`.
- ← →: go to the head, then fold or unfold it (the outline exception).
- Return: `onReturn`.

Find's panel uses it with `folds: false, takesKeyboard: false`, so the field keeps its keys. `FindRow` stays Find's.

**Tests.**
- A new DetailPanelTests suite, `walkListTests`: the window, folding, head labels, and keys stepping a fixture walk.
- `PanelWalkTests`' `Walker` gains a walk list, walked with Tab and ⇧Tab, checked for Escape and checked inert.
- CanvasTesting's `KeyMeanings` gets a "walk list" row. Page Up and Page Down are a named exception: a list grouped by board pages by board.
- FindTests' panel tests are unchanged.

**Docs.** detail-panel.md ("The panel by keys"), find.md (FindPanel), keyboard-navigation.md (the table, and a "Walk lists" line), and the guide's §The detail panel.

## Landing 4: the band point, `DetailBands`

It goes in `Sources/DetailPanel/DetailOverview.swift`, beside takeovers:

```swift
public enum DetailBands: ExtensionPoint   // owner .detailPanel, summary "detail band"; first active shows
extension PluginRegistrar {
    public mutating func detailBand<Content: View>(isActive: @escaping @MainActor (CanvasEditor) -> Bool,
        onCancel: @escaping @MainActor (CanvasEditor) -> Void,
        @ViewBuilder content: @escaping @MainActor (CanvasEditor, @escaping @MainActor () -> Void) -> Content)
}
public enum DetailKeyboardPlace { case band, takeover, content }
// DetailPanelState: public private(set) var keyboardPlace: DetailKeyboardPlace?;  public func focusBand()
```

**Where it shows.** The band and a divider go above everything in `DetailPanelView.body` (`:50-52`): a takeover, the overview, or a shape's header and tabs.

**Escape and ⌘. split** (today they are one path, `:104-128`):
- Escape runs the takeover's `onEscape`. Then, with a band active and a takeover just closed, `focusBand()`; otherwise `onExit`. So Escape goes list, band, canvas.
- ⌘. runs the takeover's `onEscape`, then the band's `onCancel`, then `onExit`.

**Also:**
- `keyboardPlace` comes from the panel's existing first-responder watch, checked against the band's rect; Validation's light reads it.
- `isRequested` (`DetailPanelPlugin.swift:25`) holds while a band is active too.

**Tests.** `TakeoverTests` gains a `BandPlugin` and `BandModel`. They hold:
- the band over nothing selected, over a shape with its tabs, and over a takeover;
- the first of two active bands showing;
- the report, and the owner not installed;
- the Escape ladder, and ⌘.;
- `keyboardPlace`;
- the inspector requested.

`PanelWalkTests`: the band's buttons are in the ring.

**Docs.** detail-panel.md, host-slots.md, keyboard-navigation.md (the Escape ladder), and the guide's §The overview and takeovers.

## What the audit says

- Boards: gives up Find, takes DetailPanel. Both are on the platform rung, and DetailPanel doesn't reach Boards, so no cycle.
- Selection, DetailPanel and Find gain nothing.
- Validation will need Selection (for `ShapeWalk`) and Keyboard, which is its planner's to add. The walker needs no Topology: the client gives the order.

## Risks

- Lifting Find's stepping touches shipped code. Its forwarding API and untouched tests guard it.
- Escape out of Find during a walk now lands on the band, not the canvas.
- Find and an issue walk can run together, each with its own Back start. Find's takeover must come before Validation's list in plugin order.
- `step` scans past 0-stop rows: O(rows) when most are ignored.
- The AppKit key view must survive a `LazyVStack` recycling its rows.

## Decided

- The band shows over Find.
- Find's Page Up and Page Down keep moving 8 rows.
- ↑ ↓ reach dimmed rows, while ⌘' skips them.
- Each client owns a walker instance; it is no service.
- Bands are a list where the first active one shows, as takeovers are.

## Questions for the owner

1. If you hide the inspector during a walk, should the walk end (as Find does), or keep running and show the panel again on the next ⌘'?
2. When the current stop has just been ignored, should the band read "– of 62" or keep its number, "12 of 62"?
