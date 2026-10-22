# Mentions phase 2: the build plan

This is the contract every agent building Mentions phase 2 works from. Read it whole, then your
area's survey report (`survey-<area>.md` beside this file: facts about main with file:line, and a
proposal this plan adopts unless it says otherwise).

- **The design** is `../design-final.md`. Its **Amendment 1** (at the top) overrides its body.
  Main has moved past the design in places (subboards, undo, mentions across boards, schema cards);
  where main and the design differ, **main wins**, and this plan wins over both.
- **The repo**: integration branch `mentions-phase2`, worktree
  `/Users/zekenie/code/native-canvas/.claude/worktrees/mentions-phase2`, at main `8d80fa9` (green:
  `./test.sh` passes every executable). Read `CLAUDE.md` and the relevant parts of
  `docs/plugin-system.md` there, and follow them: they are the house rules.

## What phase 2 ships

1. **A panel text box any plugin can fill** (DetailPanel, generic): `open class DetailTextView`,
   `DetailTextContent`, `DetailTextBox`, the panel yielding Escape (and a text view yielding Return
   and ⌘↩) to a text view that holds keys, and a section shown by a predicate that reads services.
2. **Mention text in the panel**: `MentionTextArea`, a `DetailTextBox` over `MentionTextView`
   (which becomes a `DetailTextView`), pills tinted (`MentionSurface.neutral`).
3. **Task cards' notes hold mentions**: `notes: MentionText`, a v4 migration step and fixture, the
   card draws its notes through `drawMentionText` from a `TaskCardLayout` shared with its
   `mentionText` placements (faces: a click selects the task, a double-click follows, the pointer
   hovers the target), and its panel's Notes field is a `MentionTextArea`.
4. **Backlinks**: a "Mentioned In" tab on the kinds that opted into being mentioned, shown only
   while something on the board shown mentions the shape, a line per mentioner (its symbol, name
   and a quote around the mention; the pointer hovers it, a click goes to it); and "Show What
   Mentions" in the canvas's context menu for a mentioned shape and in a pill's menu in text,
   selecting what mentions it.
5. **MentionValidation** (a bridge: Mentions and Validation): warnings for a mention of a shape
   that can't be mentioned, a mention outside its text's scope, and text that looks like a mention
   but isn't. Never for a missing shape (decision 3A: the dashed pill says it).
6. **EllipseMentions** (an example bridge: Ellipses and Mentions): ellipses are mentionable, named
   by their derived title ("Ellipse, 200 × 140").
7. **Cut then paste is a move** (Clipboard, decision 5A): a paste of what a cut took keeps each id
   no shape in the file has, so mentions of what moved stay live, across boards too.

Not in phase 2 (stay in "Not built yet"): checklist items holding mentions, the picker reaching
other boards, a subboard mentionable, backlinks and validation across boards (both read the board
shown), CLI helpers, creating shapes from the picker, a shipped restricted text.

## Decisions (the user's standing ones, then this plan's)

The user decided (Amendment 1; memory): missing pills (dashed, stored name, undo revives, nothing
written); two selection planes (a click selects a pill as text, a double-click follows); pills show
the kind's symbol and the name, no "@", monochrome on a shape's surface, **tinted in the panel and
the picker**; notes and tasks mentionable; live labels; restriction by scope; fuzzy search. The
design's other defaults stand: 3A (no warning for missing), 5A (cut and paste is a move), 11A (a
"Mentioned In" panel section, no count chip).

This plan decides:
- **Quiet copy.** Tab "Mentioned In". Menu items "Show What Mentions" (canvas) and
  "Show What Mentions “Name”" (pill menu in text). Warnings, short sentences with periods and
  curly quotes: `“Name” can’t be mentioned.`, `“Name” can’t be mentioned here.`,
  `“@[x](shape: 7C1E…” isn’t a mention.` (a look-alike cut to about 30 characters with "…").
  No instructions, no counts, nothing said twice.
- **Backlinks and validation read the board shown**, as the index does. Mentioners on other boards
  aren't listed; a mention of a shape on another board isn't checked. Say so in the docs.
- **The "Mentioned In" tab** (`MentionsTab`, order 300: a tab of the shape's state that comes and
  goes, as Issues) comes with the opt-in: `x.mentionable(…)` and `registrar.mentionable(K.self, …)`
  also contribute its section (`details`), so opting in brings the tab ("scope to the opt-in").
  `mentionableEveryShape(where:)` brings no tab (the panel has no every-shape section over the
  record); say so. So every plugin list with a mentionable kind needs `DetailPanelPlugin()`, and
  every list with `MentionsPlugin()` needs `ContextMenusPlugin()` (the canvas's menu item).
- **A task's notes that hold a mention reserve the whole clamp** (2 lines): a placement is made from
  the shape alone and a pill's width follows its target's live name, so measuring would let the
  render and `mentionPills` disagree about where the checklist starts. Plain notes measure exactly
  as today, and draw pixel for pixel as today.
- **Cut marker: a token on the pasteboard.** A cut writes a fresh UUID string under
  `com.example.InfiniteCanvas.cut` beside the shapes, in the same write (a copy writes none; any
  later write clears it). A paste with a token keeps each id the file doesn't use
  (`CanvasFile.isUnused(_:)`, new, core: no shape, no board kept under it, no unreadable entry kept
  under it) and gives the rest new ids, one map for bindings and names; a kept id gets no
  `CopiedFrom` (it's the same shape, moved). No ledger of pastes: the first paste's shapes use the
  ids, so a second paste copies; undoing the paste frees them again. A copy is never a move.
  Bindings from outside what was cut still let go at the cut (they must be on their board); only
  names survive a move. Say so.
- **Panel field commits** write through the binding on every change, as the panel's text boxes do
  (a field's run of writes is one undo step, "Change Notes"); no `onCommit` for task notes, so
  Return is a new line. A pick, Remove Mention and a paste are writes of that run.
- **`BoardWindow`'s seal on a click in another window** skips a window whose parent is a
  `BoardWindow` (the picker, a child window), so a pick with the mouse stays in the typing's step.

## Public API (the contract; owners may add, never change these without saying so in their result)

```swift
// DetailPanel (PANEL): TextViews.swift, Controls.swift, DetailPanel.swift, DetailPanelState.swift,
// DetailPanelView.swift, ShapeBinding.swift
@MainActor open class DetailTextView: NSTextView {
    public var onCommit: (@MainActor () -> Void)?     // ⌘↩, the keyboard leaving, leaving the window; nil: none of them is taken
    public var commitsOnReturn: Bool                  // Return commits, ⇧↩ a new line; only with onCommit
    public var onExit: (@MainActor () -> Void)?        // Escape, when set
    public var placeholder: String?                   // drawn while empty
    open var holdsKeys: Bool { false }                // while true: Return, ⌘↩ and Escape are the view's own
}                                                     // (doCommand(by:)), never the panel's or onCommit's
@MainActor public protocol DetailTextContent: DetailTextView {
    associatedtype Value: Equatable
    var value: Value { get }
    func show(_ value: Value)                         // from outside: storage only, never didChangeText, never commits
}
public struct DetailTextBox<Content: DetailTextContent>: View {
    public init(_ value: Binding<Content.Value>, height: CGFloat = DetailStyle.textAreaHeight,
                placeholder: String? = nil, onCommit: (@MainActor () -> Void)? = nil,
                make: @escaping @MainActor () -> Content)
}
extension DetailStyle { public static var textFont: NSFont { get } }   // the panel's text, 11 pt
extension DetailSection {
    /// Shown while `isShown` says so, read on every commit (as status lines are), so it may read
    /// services; it must cost O(1) (a cached service read). Beside `when:`, which reads the value.
    public func shownWhile(_ isShown: @escaping @MainActor (AnyShapeRecord, DetailContext) -> Bool) -> Self
}
extension ShapeBinding { public var shapeID: ShapeID { get } }   // the shape a binding writes, for every Value

// Mentions, backlinks and menus (BACKLINKS, phase 1): MentionState.swift, MentionBacklinks.swift (new),
// MentionMenus.swift (new), MentionTextView.swift (pill menu only in phase 1), MentionStyle.swift, Mentions.swift
public struct MentionBacklink: Hashable, Sendable {
    public let id: ShapeID; public let label: String; public let systemImage: String
    public let quote: String                          // ~60 characters of plain text (live names) around the
}                                                     // first mention of the target, one line, "…" at each cut
extension MentionState {
    public func isMentioned(_ target: ShapeID) -> Bool                 // by another shape on the board shown; O(1)
    public func backlinkRevision(of target: ShapeID) -> Int            // observed per target (SwiftUI), as labelRevision
    public func backlinks(of target: ShapeID) -> [MentionBacklink]     // document order, the target itself left out
    public func showWhatMentions(_ targets: [ShapeID])                 // goTo their mentioners on the next scheduler turn
}
public enum MentionsMenuGroup: MenuGroup {}          // order 50; "Show What Mentions", an item for the canvas

// Mentions, the field and the tab (FIELD, phase 3)
extension MentionTextView: DetailTextContent { public var value: ScopedMentionText<Scope>; public func show(_:) }
// MentionTextView<Scope>: DetailTextView, holdsKeys { picker != nil }; its public API otherwise unchanged
public struct MentionTextArea<Props: ShapeProps, Scope: MentionScope>: View {
    public init(_ shape: ShapeBinding<Props>, _ field: WritableKeyPath<Props, ScopedMentionText<Scope>>,
                height: CGFloat = DetailStyle.textAreaHeight, placeholder: String? = nil,
                onCommit: (@MainActor () -> Void)? = nil)
}
public enum MentionsTab: DetailTab {}                // "Mentioned In", order 300

// Mentions, problems (VALIDATION): MentionProblems.swift (new), MentionText.swift, MentionTextFormat.swift
public struct MentionProblem: Hashable, Sendable { public let property: String; public let message: String }
extension Registry {
    /// What's wrong with the mentions a shape's text holds: targets that can't be mentioned or are
    /// outside their text's scope (looked up through `lookup`, so Validation records the lookups),
    /// and text that looks like a mention but isn't. Nothing for a shape `lookup` doesn't find.
    @MainActor public func mentionProblems(of shape: AnyShapeRecord, lookup: (ShapeID) -> AnyShapeRecord?) -> [MentionProblem]
}
extension ScopedMentionText { public var lookalikes: [String] { get } }   // unescaped "@[" that didn't parse, with "(shape" later on its line

// Validation (VALIDATION)
extension ValidationContext { public var registry: Registry { get } }

// Canvas (CLIPBOARD)
extension CanvasFile { public func isUnused(_ id: ShapeID) -> Bool }

// MentionValidation (VALIDATION): Sources/MentionValidation, layer bridge, deps Canvas, Mentions, Validation
public struct MentionValidationPlugin: CanvasPlugin { public init() }   // id "mention-validation"
// EllipseMentions (VALIDATION): Examples/EllipseMentions, layer bridge, deps Canvas, Ellipses, Mentions
public struct EllipseMentionsPlugin: CanvasPlugin { public init() }     // id "ellipse-mentions": registrar.mentionable(Ellipse.self)
```

## Areas, owners and files

Each file has one owner in a phase; nobody edits another's file. Shared files (Package.swift, the
test `main.swift` lists, `ShippedTests.swift`'s pinned report and the same block in
`docs/plugin-system.md`) each owner edits **only the lines of its own change**; the integrator
unions them. Everything else in `CLAUDE.md` and `docs/plugin-system.md` is the DOCS agent's, last.

**Phase 1, in parallel, each in its own clone:**

- **PANEL** (DetailPanel's lends, generic; knows nothing of mentions): `Sources/DetailPanel/*`,
  `Sources/CanvasUI/BoardWindow.swift` (the child-window seal exemption), `Tests/DetailPanelTests/*`,
  and BoardWindow tests (`Tests/CanvasUITests`). Extract schema cards' private `PanelTextView.TextView`
  into `open class DetailTextView` (every behavior inert unless configured: ⌘↩ passes through
  without `onCommit`), an internal `PlainTextView: DetailTextView, DetailTextContent` (`Value ==
  String`) with the code editor's behaviors, and `DetailTextBox` (it builds its `NSScrollView` by
  hand around `make()`, never `scrollableTextView()`; its coordinator keeps the binding discipline:
  `show` only when the binding changed from outside, then clears the box's undo; `textDidChange`
  writes `view.value`; `undoManager(for:)`). `DetailCodeEditor` and `DetailTextArea(onCommit:)` become
  boxes over `PlainTextView` and behave exactly as before (their tests pass unchanged; the
  `TextEditor` branch of `DetailTextArea` stays). The root's Escape returns `.ignored` while the
  first responder is a `DetailTextView` that holds keys; pin with a test that the text view then
  gets `cancelOperation:` (the design's probe said the ancestor sees Escape first). `shownWhile`
  evaluated beside `statuses(of:)` in `DetailPanelView.body`, only over the sections that have one
  (cached per kind), passed into `ShapePanel` and its `==`, and into `layout(for:)` headlessly; a
  tab shows only while it has a section shown. Tests with a fixture `DetailTextView` subclass (a
  String-wrapper `Value`, a settable `holdsKeys`, logging `doCommand` selectors and `show`s), per the
  survey's list.
- **BACKLINKS** (Mentions' state, menus; phase 1 needs no DetailPanel API): `MentionState.swift`
  (the four methods; `backlinkRevision` bumps for the old ∪ new targets of each shape a commit adds
  or changes (not one it only moved) and the old targets of each it removes, from what `hear` and
  `reindex` already know; a drag costs nothing), new `MentionBacklinks.swift` (`MentionBacklink`,
  the quote), new `MentionMenus.swift` (`MentionsMenuGroup`, the canvas's item through
  `registrar.contextMenuForCanvas`, shown when a shape the menu is for is mentioned, running
  `showWhatMentions`), the pill menu's "Show What Mentions “Name”" in `MentionTextView.swift`
  (`menu(for:)` only; a live pill whose target is on the board shown; runs on the scheduler's next
  turn, since it ends editing), strings in `MentionStyle.swift`, the registration in
  `Mentions.swift`, Package.swift's Mentions line (+ `"ContextMenus"`, `"DetailPanel"`) and
  MentionsTests line (+ `"ContextMenus"`, `"DetailPanel"`), and `Tests/MentionsTests/*` (add
  `ContextMenusPlugin()` wherever `MentionsPlugin()` is listed; `DetailPanelPlugin()` too, ready
  for phase 3). Also every other test list with `MentionsPlugin()` outside MentionsTests
  (StickyNotesTests, TaskCardsTests, and any other): add `ContextMenusPlugin()` if missing, editing
  only those lines. Update the pinned report lines for `mentions` (ShippedTests and the docs'
  block). Tests: StateTests for the revision (bumps and non-bumps: a drag, unrelated targets, undo
  and redo, a self-mention), `backlinks` order and quotes (a cut at each end, a mention at the
  start, live names in the quote); menu tests (`h.secondaryClick`, `menu.outline`, `menu.choose`)
  that it shows only for a mentioned shape and selects the mentioners with one Back step; the pill
  menu item in TextViewTests.
- **TASKS** (task cards' notes): `Sources/TaskCards/*` (not `TaskCardPanel.swift`'s Notes field,
  which FIELD changes), new `Sources/TaskCards/TaskCardLayout.swift`, `Tests/TaskCardsTests/*`,
  `Tests/CompositionTests/Fixtures/kinds/task-card.v4.json` (new; set every member; `notes` with a
  real mention with an uppercase id, a label with `\]` and `\\`, an escaped look-alike `\@[`, a
  backslash before a mention; written once from the codec, never edited after), the task-card
  cases in CompositionTests' `PersistenceTests.swift`, `SchemaTests.swift` and
  `CommandLineTests.swift`, and the task-card line of the pinned report. The v4 step:
  `PropsMigration("notes may mention shapes") { MentionTextFormat.escapeLookalikesV1(in: &$0, "notes") }`
  (tolerating a task without `notes`). The rule becomes `props.notes.isBlank`. The render and
  `task.mentionText { TaskCardLayout($0).mentionTexts }` (registered just before
  `task.mentionable`) share `TaskCardLayout`; `TaskStyle.notes = MentionTextStyle(font: bodyFont,
  color: secondary color)` with **no** `lineHeight` (a paragraph style would move line 2) and the
  default surface; the placement passes no `lines:`; the box's height is exactly today's for plain
  notes, the whole clamp for notes holding a mention. Tests: plain notes pixel for pixel as today
  at 1× and 2× (one, two and three lines clamped; against the card drawn before this change: keep
  a copy of today's drawing code in the test, or compare to a hand-drawn string in the same box);
  pills inside the notes box (`editor.mentionPills`), none while notes are hidden, none past the
  clamp; a line with a pill starts where it would without (`lineTops`); the checklist two lines
  down with a mention; a rename changes only pixels in the pill's frame; delete and undo; faces (a
  click selects the task, no edit, no shake; a double-click follows and Back returns; hover); the
  rule with a mention; `mentioners(of:)`. Run `./build.sh bench` once and report the numbers
  (tasks became a naming kind: the index at 10,000 must stay within 50 ms).
- **VALIDATION** (the bridges and their lends): `Sources/Validation/Validation.swift` (only
  `ValidationContext.registry`, and if the bench needs it, the lookup below), new
  `Sources/Mentions/MentionProblems.swift`, `Sources/Mentions/MentionText.swift` and
  `MentionTextFormat.swift` (the look-alike scan; `MentionTextHolding` may expose its scope
  internally), new `Sources/MentionValidation/MentionValidation.swift`, new
  `Examples/EllipseMentions/EllipseMentions.swift`, Package.swift lines for MentionValidation,
  EllipseMentions, Composition's deps, a new `MentionValidationTests` target (+ its `main.swift`),
  ExamplesTests' deps, BenchmarkTests' deps; `Sources/Composition/ShippedPlugins.swift`
  (`MentionValidationPlugin()` after `ValidationContentsPlugin()`, `EllipseMentionsPlugin()` after
  `EllipseTitlesPlugin()`), `Tests/ExamplesTests/*` (EllipseMentions tests; its lists add
  `MentionsPlugin()`, `ContextMenusPlugin()`, `DetailPanelPlugin()`), `Tests/ValidationTests/*`,
  `Tests/BenchmarkTests/*` (the sparse board becomes rectangles, since ellipses are now
  mentionable; add validation's read after a drag event of the task mentioned 100 times, held to
  `Budget.validationAfterCommit` (1 ms), and after renaming it, held to 1 ms more than one
  mentioned by none), and the pinned report lines for the two bridges. The rule:
  `registrar.validateEveryShape { shape, context in … }` returning at once unless
  `context.registry.namingKinds.contains(shape.kind)`, mapping `mentionProblems(of:lookup:
  context.shape)` to `.warning(message, field: property)`. Each target once per text; a target
  `lookup` doesn't find, or kept aside, is nothing. The unmentionable name is the name the mention
  holds, else the kind's name; the out-of-scope name is the live one. If the drag bench is over
  budget (every drag event of a mentioned task re-checks its mentioners through the lookups), add
  a generic lend to Validation, a lookup that a move doesn't re-check
  (`context.shape(_:ignoringMoves:)` or similar, using `ChangeSet.moved`), and use it. Tests
  (MentionValidationTests, with its own fixtures: a mentionable kind, an unmentionable one, a kind
  with a `MentionText` and a `ScopedMentionText<Only<…>>`): each warning with its field; missing
  and kept-aside targets don't warn; deleting the unmentionable target clears the warning and undo
  brings it back; out-of-scope only for scoped text; look-alikes (a bad UUID, `shape: ID` with a
  space, an unescaped `]`), and never for canonical text (fuzz: `ScopedMentionText(runs).stored`
  has no look-alikes) or `\@[`; a locked mentioner is still checked. ExamplesTests: the ellipse's
  appearance, the picker offers it, a resize renames it, delete and undo, "Untitled Ellipse"
  without EllipseTitles, and the refusals.
- **CLIPBOARD** (cut and paste is a move): `Sources/Clipboard/*`,
  `Sources/Canvas/Model/CanvasFile.swift` (`isUnused` only), `Tests/ClipboardTests/*`,
  `Tests/CanvasTests` (an `isUnused` test), and the CompositionTests that pin today's cut and paste
  (`MentionsBoardsTests.swift`'s cut test, inverted; `MentionsShippedTests.swift`'s copy test; and
  wherever `SubtreeTests` live). Tests per the survey's list: ⌘X ⌘V keeps ids with no
  `copiedFrom`, a second ⌘V copies; ⌘C, Delete, ⌘V copies; another write clears the token; undo
  the cut then paste copies; cut in one editor and paste in another on the same pasteboard keeps
  ids there; a partial keep (one id in use) with a link and a naming memo pointing right; an orphan
  board or unreadable entry under a cut id gives a new id, no crash; a moved shape keeps its old
  `CopiedFrom`; a cut whose delete was refused pastes a copy; undo and redo of a move; across
  boards: cut a mentioned note inside a subboard, paste on the root, the mention from outside is
  live and followed there.

**Phase 2, the integrator** (in the integration worktree itself): merge the five branches, resolve
conflicts (unions of Package.swift lines, test lists, the pinned report), run `./build.sh audit`
and `./test.sh` whole, and fix what the merge broke.

**Phase 3, FIELD** (in the integration worktree): `MentionTextView` becomes a `DetailTextView`
(`holdsKeys`, `DetailTextContent` with `show`: the storage from the value, the caret clamped,
`reported` set, targets observed again and pills fitted, tooltips stale, the picker closed; never
`didChangeText`), `MentionTextArea`, `MentionStyle.panelText` (`DetailStyle.textFont`, label color,
`.neutral`), the "Mentioned In" tab and its view (reads `backlinkRevision` and each line's
`labelRevision`, `$x.service(MentionState.self)`; a row's hover and click through `hover`,
`endHover`, `follow`; `.enabledWhileReadOnly()`; contributed by the `mentionable` sugar),
`TaskCardPanel.swift`'s Notes field → `MentionTextArea($task, \.notes)`, and tests: MentionsTests'
`PanelTests.swift` (a `Jot` section in `DetailPanelView` in an unshown window with the real
`TaskScheduler`: `@gro` ↓ ↩ writes the canonical text as one step; Escape closes only the picker, a
second exits; with `onCommit`, Return picks and doesn't commit; a click selects a pill, a
double-click follows and Back returns; Delete takes a pill; ⌘C/⌘V on `withUniqueName()`; a rename
redraws the pill with no transaction; a board undo shows the old text and writes once; a text undo
in a `BoardWindow`; read-only: not editable, no picker, a double-click still follows; the picker
under the `@` and closed when it scrolls out; a mouse pick in the typing's step), the tab's tests
(shown only while mentioned, lines in order, hover, click, gone with the last mention, redrawn by
a mentioner's rename without the panel's record changing), CompositionTests on the shipped task
panel in a `BoardWindow`, and a bench line: the panel's layout for a task mentioned 100 times,
read after a drag of an unrelated note and after renaming one mentioner, held to 1 ms.

**Phase 4, DOCS**: `CLAUDE.md` and `docs/plugin-system.md` for all of it (the survey
`survey-examples-composition.md` lists the places), in the house voice.

## Rules for every agent

- Work only where your prompt says (your clone, or the integration worktree); commit on your own
  branch there; never touch `main`, never push. Build and test there: `./build.sh audit`,
  `TEST_FILTER=… ./test.sh`, `./test.sh`. If the build says "this SDK is not supported by the
  compiler", prefix `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. Swift 6,
  `-warnings-as-errors`. Other agents build at the same time: builds are slow; never kill other
  processes; `BUILD_JOBS=4 TEST_JOBS=4` is kind to the others.
- Before you finish: the audit passes, your tests pass, and `./test.sh` passes whole (every
  executable). Commit with a message that leads with intent (why, what was decided, what was
  rejected), ending with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- `@testable` is refused: tests use public API only. Every new `Suite` goes in its target's
  `main.swift`. Conform to protocols with defaulted requirements in extensions.
- Screen capture isn't permitted. Nothing goes on screen: unshown windows only. Never touch the
  user's pasteboard (`NSPasteboard.withUniqueName()`, `releaseGlobally()`). Never print, log or
  write an API key. Scratch files go in the scratchpad, never /tmp.
- UI copy is quiet: terse, no instructions, each thing said once. Comments and docs read like the
  surrounding code: plain sentences saying what is and why.
- Nothing may transact in `documentDidChange` (undo's precondition). A text view's `show` never
  calls `didChangeText`.
- If something in this plan is wrong against the code, do the right thing, and say what and why in
  your result.
