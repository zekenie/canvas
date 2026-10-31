# Plan: issues (Validation, LanguageRules, the keys)

Four landings, after the walker landing. Each one is tested and committed before the next.

## What I need from the walker planner

- **Selection, `ShapeWalk`** (from `FindState.swift:363–490`). It takes stops the client orders, `WalkStop(key: AnyHashable, shape:, board:)`, and offers:
  - `setStops(_:keeping:)`, which keeps the current stop current;
  - `skipped:` rows that stay listed but that ‹ ›, N and the ordinal pass over;
  - `step(forward:)` (wraps), `move(by:)`, `moveBoard(by:)`, `go(to:)`;
  - a pending step (Find's), `start` (`FindState.swift:187`), and every move inside `navigate(from:)`;
  - `selects` (`goTo`), `onArrive`, live `ordinal`/`count`, and `finish()`.
- **One order.** `FindSearch.order(of:topology:file:)` (`FindSearch.swift:133`) moves into Topology as `TopologySnapshot.boardOrder(from:file:)`. If the walker landing doesn't move it, my landing 2 does.
- **DetailPanel:**
  - `registrar.detailBand(isActive:) { editor in … }`: one holder, over a shape's panel and over takeovers, first in the Tab ring, Escape to the canvas;
  - `WalkList`: the row window, `BoardHeadings` heads, fold keys, Page Up/Page Down as the client says, client rows with labels, dimmed rows, and an announcement hook;
  - `DetailTabView(editor:record:tab:)`: one tab's status lines and sections, as `ShapePanel` draws them (`DetailPanelView.swift:344`), with no header or strip;
  - `detailTakeover(…, onCancel:)`, so ⌘. can mean something other than Escape.

## Landing 1: where an issue comes from

- `ValidationIssue.source: IssueSource?` (`Validation.swift:22`; init `:32`, sugar `:40–44`).
- `IssueAction.role` (`.ignore`, `:57`); equality stays by title (`:66`).
- LanguageRules' warnings (`RuleChecks.swift:286`) carry `.rule(RuleKey)` (`:28`), and their Ignore carries `role: .ignore`.

```swift
public struct IssueSource: Hashable, Sendable { public init(plugin: PluginID, key: String) }
```

- **Tests:** ValidationTests `issuesTabTests` (source and role kept through the engine and `validationIssues(of:in:editor:)`, `:556`); LanguageRulesTests `ruleChecksTests` (a warning's source is its RuleKey).
- **Topic files:** validation.md, language-rules.md.

## Landing 2: `IssueWalk`, scopes, Next/Previous, Ignore

New files are `Sources/Validation/IssueWalk.swift`, `IssueScopes.swift`, `IssueWalkCommands.swift` and `IssueWalkStyle.swift`. They live in a plugin value, `Validation.IssueWalkPlugin`, after `ValidationDetailsPlugin` (`Package.swift:158`).

```swift
public struct IssueScope: Sendable {   // `.all`: errors and warnings that show
    public let id: String
    public let includes: @Sendable (ValidationIssue) -> Bool
    public let label: @MainActor (CanvasEditor) -> IssueScopeLabel?        // "Rule 1", chip name + color, spoken "Rule 1 of Vote"
    public let candidates: (@MainActor (CanvasEditor) -> Set<ShapeID>)?    // nil: gather by query
}
public enum IssueScopes: ExtensionPoint {}   // registrar.issueScopes { source, editor in IssueScope? }
@Observable public final class IssueWalk: EditorService {   // editor.issueWalk
    public var scope: IssueScope?; public var rows: [IssueRow]   // .live / .ignored / .holds
    public func begin(_: IssueScope, at: ShapeID? = nil, forward: Bool = true)
    public func step(forward: Bool); public func ignoreCurrent(); public func end()
    public func place(of: ShapeID, source: IssueSource) -> (ordinal: Int, count: Int)?
}
```

**Stops.** A stop is one error or warning that shows and that the scope includes, worst first within its shape. Incomplete issues are never stops; unsure answers are no issues at all.

- **Gather.** From the scope's `candidates`. A scope without them runs `:invalid, :warned` through `queries.run` with `settle: nil`, which doesn't wait.
- **Read.** Each shape's issues are read on the main actor, as `ValidationQueries.swift:58` reads them.
- **Order.** Stops are sorted by `boardOrder` ranks, kept until a commit that isn't only moves.
- **Arriving.** `documentDidSettle` re-reads the shapes a commit changed plus `affected(by:)`. `recheck(_:)` (`Validation.swift:406`) also hands the walk its ids on every board, because answers land with no commit. New stops join through `setStops(keeping:)`.
- **Gone.** A stop whose issue goes stays as a `skipped` row. It reads "ignored" if the last action on it had `role == .ignore` (the walk's, or the line's button, which `IssuesTab.swift:20` now wraps), else "holds". Undo makes it live again. A dead row keeps its ordinal; N counts live stops only.

**At a stop:** the Issues tab is chosen (as `RuleWriter.swift:97` does), and `editor.announce` (`Accessibility.swift:265`) says "Issue 12 of 63, Texas, …" (the board only when it changed). Ignore says "Ignored, 62".

**Names:** `registry.title(of:)` (`Titles.swift:368`); an arrow by its ends, as `RuleChips.swift:315` does.

**Commands.**
- `.nextIssue` ⌘' and `.previousIssue` (`KeyChord("\"", .command)`, ⌘?'s convention) repeat and run `.betweenPresses`. They sit in a new `IssuesSection` in Go, `.after(NavigationSection.self)` (`Selection.swift:44`).
- With no walk running, they begin All Issues after the selection (before it, for Previous).
- `.ignoreIssue` ⌥⌘' is enabled while the current stop is live and has an `.ignore` action. It is a `forEveryShape` item in `StateMenuGroup`, shown while the selection is the current stop, so it appears as Shape › Ignore Issue.
- ⌘[ goes back to the start, and the walk goes on.

**LanguageRules** adds `registrar.issueScopes`. A rule's scope has `flagged(by:)` as its candidates (`RuleChecks.swift:239`, observed) and "Rule n" with the type's chip as its label, read live. `RuleScopes.scope(for:)` is shared by the point and by FlagCount.

**Tests.**
- ValidationTests `issueWalkTests` (new file; the target adds Selection, Topology and Keyboard), over fixture rules with sources on pocket boards:
  - order across boards, the wrap, and ⌘' then ⇧⌘';
  - one Back step, with the camera still when the shape is in view;
  - Ignore keeping its row, "holds" after a fix, and undo;
  - a stop arriving through `recheck` on a board not shown;
  - incomplete issues never walked, and the announcements.
- LanguageRulesTests `ruleWalkTests`: the scope is the flagged shapes, an unsure answer is never walked, and ⌥⌘' is one "Ignore Rule" step.
- KeyboardTests: `"` with ⇧⌘ reaches Previous.
- CompositionTests: `keyboardShortcutsShippedTests`, BoardDocumentTests (Go's items), `shapeMenuShippedTests`, `keyMeaningsShippedTests`, `reachCensusTests` (Ignore Issue has its key).
- **Topic files:** validation.md (a "The walk" bullet), keyboard.md, keyboard-navigation.md, language-rules.md, plus a guide section after "A tab of status lines".

## Landing 3: the band, the count's click, "9 of 63", the light

`Sources/Validation/IssueWalkPanel.swift`, in a plugin value `Validation.IssueWalkPanelPlugin`, after DetailPanel and Boards' heading plugin.

- **The band** shows the scope's chip and "Rule 1", else "All Issues"; then ‹ "12 of 63" › and Done.
  - The count, clicked or with Return, opens the list (landing 4).
  - Done, or ⌘. while the band has the keyboard, ends the walk.
  - VoiceOver hears "Rule 1 of Vote", "12 of 63", "Previous Issue", "Next Issue" and "Done".
- **"9 of 63"** is Validation's: `IssuesTab.swift` adds it to any issue whose source resolves to a scope with `candidates`. It reads `place(of:source:)`, which the panel's body observes (`DetailPanelView.swift:69`). It is left off the line the walk is on.
- **FlagCount** (`RulesPanel.swift:121`): a click or Return begins the rule's walk.
- **The light** is Validation's `registrar.outlines` (`CanvasPlugin.swift:55`): the walk's other live stops on the board shown, while the band or the list has the keyboard. `IssueWalkStyle.light` takes over `RulesStyle.light` (`RulesStyle.swift:108`), which now reads it.
- **Tests:**
  - ValidationTests `issueBandTests` in an unshown window: Tab order, Escape, Done, a `KeyWalk` with Keyboard navigation on and off, the line's action, the light's pixels;
  - LanguageRulesTests `ruleWindowTests`: the count begins at stop 1, and Select Flagged ▸ still selects;
  - CompositionTests `languageRulesShippedTests`: stops across boards;
  - the gallery's band frames.
- **Topic files:** validation.md, language-rules.md, detail-panel.md, keyboard-navigation.md.

## Landing 4: the list, Issue List, the evidence

- **Issue List** is `.issueList` ⌃⌘' in `IssuesSection`. It toggles the list of the walk running, else begins All Issues with the list open.
- **The list** is a takeover (`isActive: walk.isListOpen`) holding `WalkList`, with `DetailTabView` of the current stop's `IssuesTab` under it. LanguageRules' Rules and Shown sections show there with no import.
- **Keys:** ↑ ↓ step; Page Up/Page Down go a board back and on; ← → fold; Return closes on the stop; Escape goes to the band; ⌘. (`onCancel`) ends the walk.
- **Rows:** a row is the name and, at its end, the first value. That value comes from a new keyed point, `IssueRowDetails`, which Types fills in `Types.IssueRowValuesPlugin` from the first text of `FieldFind.swift:87`/`:105`. A head reads "Texas 9" (VoiceOver: "Texas, 9, collapsed"); a row reads "name, board, 12 of 63".
- **Tests:** ValidationTests `issueListTests` (order, heads folded but the current board's, a dimmed "ignored" row, Return, the Escape ladder, ⌃⌘' as a toggle, a `KeyWalk`); CompositionTests (the evidence shows LanguageRules' sections; the gallery's list frame).
- **Topic files:** validation.md, types.md, keyboard-navigation.md.

## The audit

Validation (`Package.swift:294`) gains Selection, Keyboard, Topology, Titles and ContextMenus: all platform, none importing Validation, so no cycle. ValidationTests gains Selection, Topology and Keyboard. LanguageRules and Types gain nothing.

## Risks

- **The House board** (14,547 shapes). All Issues' gather runs rules on the main actor for boards not shown; `candidates` spares FlagCount. I'll add `issueWalkGather10k` and `issueWalkStep` benchmarks.
- **Opening the list** drops a field's draft, so it ends editing first.

**Decided:** ⌘. ends the walk only from the band or the list (on the canvas it stays Cancel), and a rule's scope goes by RuleKey.

## Questions for the owner

1. **Done with Keyboard navigation off.** The band's Done then has no menu way. Should there be a Go › End Issue Walk? I recommend yes.
2. **A rule reworded mid-walk.** The rule gets a new RuleKey, so every stop would read "holds". Should the walk follow the new wording and re-gather, keeping its place? I recommend yes.
3. **Previous Issue's chord.** Its key is registered as ⌘", so menus may show ⌘" rather than ⇧⌘'. Is that acceptable, or should it be another chord?
