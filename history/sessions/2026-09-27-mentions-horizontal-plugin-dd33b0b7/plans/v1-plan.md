# Mentions V1: the build plan

This is the contract every agent building Mentions V1 works from. Read it whole, then the parts of
the design it points to.

- **The design** is `design-final.md`, in this same scratchpad directory. **Amendment 1**, at its
  top, overrides the body wherever they disagree. This plan overrides both where it says so.
- **The repo** is `/Users/zekenie/code/native-canvas`. Integration branch `mentions`, worktree
  `/Users/zekenie/code/native-canvas/.claude/worktrees/mentions`, branched from main `2b1cdcf`
  (Phase 0: ShapeNaming, faces, goTo/reveal, contentsRow(affected:), EditContext.service/startPoint,
  the note's 19-pt line pitch). Read `CLAUDE.md` and `docs/plugin-system.md` there; follow them.
- **Probes** worth reusing (code that already works): `synth-probe/grammar.swift` (the stored
  grammar, fuzzed 200k times), `synth-probe/hitrect.swift` (where string drawing puts a pill),
  `rev-probe/undo2.swift`, `rev-probe/proxy.swift` (forwarding delegate in a generic NSTextView
  subclass), `rev-probe/anchor.swift`, `mentions-probe/*.swift` (pill images, clicks, highlight,
  paste, typing, zoom, plain mode), `contained-probe/`. Research: `appkit-text.md` (checks 1-15).

## What V1 is

The user asked for mentions in sticky notes, now, without waiting for the undo branch. V1 ships:

1. **A `Mentions` horizontal** (`Sources/Mentions`, layer horizontal, on Canvas, Selection,
   TableOfContents and Titles): the plugin, its points and sugar, `MentionText`, scopes, the
   `MentionState` service, the pill, drawing, faces, the text view and the `@` picker.
2. **Mentionable kinds:** sticky notes (`note.mentionable(untitled: { $0.props.text.firstLine })`)
   and task cards (`task.mentionable(symbol: { $0.props.status.symbol })`). Nothing else.
3. **Mention text:** the sticky note's `text` becomes `MentionText`, with the v3 migration and a new
   fixture. Its canvas render, its editor, and its table-of-contents row show pills / live labels.
4. **Restricted fields:** the scope mechanism (`MentionScope`, `AnyMentionable`, `Only<Kind>`,
   `DeclaredMentionScope` with `registrar.mentionScope` and `mentionable(in:)`) is built and tested
   with fixtures in MentionsTests. No shipped field is restricted yet (the note's text mentions any
   mentionable shape). The user's must-have: "a text field can be restricted to some kinds".
5. **Fuzzy search** in the picker, per Amendment 1's table (exact 1000, prefix 800, word prefixes
   600, substring 400, subsequence ≤300 fzf-style, one Damerau typo 100 for queries of 4+ that
   matched nothing above), plus §1.3's adjustments, tie-breaks, Recent and Nearby.
6. **Live labels:** a rename of a mentioned shape updates every pill (canvas render next frame, the
   editor through observation, rows through `affected:`, the picker's catalog).
7. **Missing pills:** a deleted target's pills stay, dashed, with their stored label; nothing is
   written; putting the shape back (undo, when there is one; re-inserting the same record in tests)
   makes them live again.
8. **Two selection planes** (Amendment 1): a click on a pill on the canvas selects the note and
   begins editing it with that pill's character selected (the face's `click`:
   `if !editor.isReadOnly(shape) { editor.beginEditing(shape, at: pillCenter) }`). In the editor a
   click (count 1) on a pill selects its whole character; a double-click (count 2) on a live pill
   follows it (`MentionState.follow`, next scheduler turn: `editor.goTo([target])`, ⌘[ comes back).
   On a read-only (locked) note, the canvas face's `doubleClick` follows. Delete deletes a selected
   pill; ⌘C/⌘V copies and pastes it as another mention; typing replaces it.
9. **Pills show the kind's symbol and the label, no "@"**: monochrome on a shape's surface, tinted
   on neutral surfaces (the picker).

**Not in V1** (phase 2/3 of the design): the panel field (`MentionTextArea`, `DetailTextView`),
task-card notes holding mentions, backlinks ("Mentioned In"), MentionValidation, checklist items,
subboards/cross-board, CLI commands, EllipseMentions, creating shapes from the picker.

## Decisions this plan adds

- **Undo write-back, without the undo branch.** Under TextKit 2 an NSTextView's own undo/redo
  changes its storage without `textDidChange` (`rev-probe/undo2`). `MentionTextView` fixes that for
  itself: while in a window it observes `NSUndoManager.didUndoChangeNotification` and
  `didRedoChangeNotification` of its `undoManager`, and when its `mentionText` differs from the last
  it reported, calls `didChangeText()`, so the host's `textDidChange` commits it. (When the undo
  branch lands, its `BoardWindow.changeText` also calls `didChangeText()`; a second call with the
  same text must be harmless: the host commits only a changed value.) This also fixes the gap plain
  notes have on main today.
- **Missing pills are faces too.** A click on a missing pill on the canvas selects it in the editor
  like any pill (so it can be deleted). Its double-click does nothing (no target), and it hovers
  nothing but its own note. In the editor, a double-click on a missing pill leaves it selected.
- **No hovered/pressed pill look on the canvas** (faces have no hovered state). The canvas's hover
  feedback is the target's faint outline and its row's tint (`hovering:` → `editor.hovered`). In
  the editor, pointer over a live pill hovers its target too (`MentionState.hover`/`endHover`).
- **Pills aren't links.** No `.link` attribute, no pointing hand, no single-click follow (Amendment 1).
  The text view's own context menu gets "Go to “Name”" and "Remove Mention" on a pill.
- **Quiet copy** (the user's rule): the picker's empty states are one row, "No matches" or "Nothing
  to mention"; no footers, no counts, no instructions. Section headers "Recent" and "Nearby" are
  fine. Missing pill tooltip in text: "Deleted". Unavailable: "Not available".
- **No board undo on main.** Main has no ⌘Z for the board. Tests of "undo revives" re-insert the
  deleted record with the same id.

## Module and file ownership

Mentions module files (`Sources/Mentions/`). Each file has one owner; nobody edits another's file
except the integrator. Constants: one `@MainActor enum MentionStyle` (in `MentionStyle.swift`,
Foundation's); other owners add `extension MentionStyle { static let … }` in their own files.

| File | Owner | What |
|---|---|---|
| `Mentions.swift` | F | `PluginID.mentions`, `MentionsPlugin` (registers the service; calls `registerMentionFaces(into:)`) |
| `MentionText.swift` | F | `MentionRun`, `ScopedMentionText`, `MentionText`, grammar, `ShapeNaming`, schema |
| `MentionTextFormat.swift` | F | `MentionTextFormat` (schema definition `mentions.text`, `escapeLookalikesV1`) |
| `MentionScope.swift` | F | scopes, `MentionScopes` point, joins |
| `Mentionable.swift` | F | `ShapeMentions` point, `MentionAppearance`, sugar, `Registry.mentionAppearance`, `MentionResolution` |
| `MentionState.swift` | F | the service: index, resolution, observation, rows, catalog, candidates, follow, hover, recent picks |
| `MentionMatching.swift` | F | `MentionMatcher` (fuzzy tiers), `MentionRanking` |
| `MentionRows.swift` | F | `MentionRows.affected`, `ContentsContext.plainText` |
| `MentionStyle.swift` | F | `MentionStyle` (pill constants) |
| `MentionTextStyle.swift` | F | `MentionSurface`, `MentionTextStyle`, runs ⇄ attributed string |
| `MentionPill.swift` | F | `MentionAttachment`: the pill's image and bounds in every state |
| `MentionDrawing.swift` | C (F stubs) | `MentionTextPlacement`, `MentionTexts` point and sugar, `RenderContext.drawMentionText`, memo, hit rects, `CanvasEditor.mentionPills(of:)` |
| `MentionFaces.swift` | C (F stubs) | `registerMentionFaces(into:)`: the canvas faces |
| `MentionTextView.swift` | E (F stubs) | `MentionTextView` |
| `MentionPicker.swift` | E (F stubs) | `MentionPicker` (the picker's model: rows, highlight, keys, open/close rules) |
| `MentionPickerWindow.swift` | E | the picker's child window and its rows |

Everything else: N owns `Sources/StickyNotes/*`, `Sources/TaskCards/*`, `Sources/Composition/*`, the
Package.swift lines of StickyNotes, TaskCards, Composition and the test targets it changes (not
Mentions' or MentionsTests'), existing tests outside `Tests/MentionsTests`, and
`Tests/CompositionTests/Fixtures/kinds/sticky-note.v3.json`. The integrator (I) owns docs
(`CLAUDE.md`, `docs/plugin-system.md`), BenchmarkTests, and the merge.

Tests (`Tests/MentionsTests/`): F writes `main.swift`, which lists **every** suite up front:
`runTests([textTests, scopeTests, labelTests, stateTests, matchingTests, pillTests, drawingTests,
faceTests, textViewTests, pickerTests])`. F owns `Fixtures.swift` (shared fixture plugins and
kinds), `TextTests.swift`, `ScopeTests.swift`, `LabelTests.swift`, `StateTests.swift`,
`MatchingTests.swift`, `PillTests.swift`; F creates `DrawingTests.swift` and `FaceTests.swift` (C's)
and `TextViewTests.swift` and `PickerTests.swift` (E's), each a placeholder suite with one trivial
test, which C and E replace. C and E put any fixtures of their own in their own test files, never
in `Fixtures.swift`. If C or E need another dependency on the MentionsTests line in Package.swift,
they edit only that line; the integrator unions it.

## Contracts (F implements the first part; F stubs C's and E's with these exact signatures)

Names and shapes of the public API. Owners may add more (internal or public) in their own files,
but never change these signatures without saying so in their result. `@testable` is refused by the
build's audit, so anything a test needs is public. Conform in extensions (CLAUDE.md).

```swift
// Mentions.swift (F)
extension PluginID { public static let mentions: PluginID = "mentions" }
public struct MentionsPlugin: CanvasPlugin { public init() }
// register(into:): registrar.service { MentionState(editor: $0) }, then registerMentionFaces(into: &registrar)

// MentionText.swift (F): design §2.2, §3.1
public enum MentionRun: Hashable, Sendable { case text(String); case mention(ShapeID, label: String) }
public struct ScopedMentionText<Scope: MentionScope>: Hashable, Sendable, Codable, SchemaDescribed, ExpressibleByStringLiteral {
    public init(stored: String); public init(plain: String); public init(stringLiteral: String); public init(_ runs: [MentionRun])
    public var stored: String { get }; public var runs: [MentionRun] { get }; public var mentioned: [ShapeID] { get }
    public var isBlank: Bool { get }; public var firstLine: String? { get }
    public func plainText(label: (ShapeID) -> String? = { _ in nil }) -> String      // "@Label"
}
extension ScopedMentionText: ShapeNaming {}                  // by hand: coded by hand as one string
public typealias MentionText = ScopedMentionText<AnyMentionable>
public enum MentionTextFormat { public static func escapeLookalikesV1(in props: inout JSONObject, _ member: String) }

// MentionScope.swift (F): design §2.3 (no `noun`: quiet copy dropped scoped empty states)
public protocol MentionScope: Sendable { @MainActor static func admits(_ shape: AnyShapeRecord, in registry: Registry) -> Bool; static func schemaAnnotation() -> JSONObject? }
public enum AnyMentionable {}; public enum Only<Kind: ShapeProps> {}
public protocol DeclaredMentionScope: MentionScope { static var title: String { get } }
public enum MentionScopes {}                                  // the declarations
extension PluginRegistrar { public mutating func mentionScope<S: DeclaredMentionScope>(_: S.Type) }
extension ShapeRegistrar { public mutating func mentionable<S: DeclaredMentionScope>(in scope: S.Type) }
extension PluginRegistrar { public mutating func mentionable<P: ShapeProps, S: DeclaredMentionScope>(_: P.Type, in scope: S.Type) }

// Mentionable.swift (F): design §2.1
public enum ShapeMentions {}                                  // KeyedExtensionPoint, one per kind
public struct MentionAppearance: Hashable { public var label: String; public var isPlaceholder: Bool; public var systemImage: String; public var kindName: String; public var detail: String; public var tint: NSColor? }
extension ShapeRegistrar { public mutating func mentionable(label: …? = nil, untitled: …? = nil, symbol: …? = nil, detail: …? = nil, tint: …? = nil) }
extension PluginRegistrar { public mutating func mentionable<P: ShapeProps>(_: P.Type, label:untitled:symbol:detail:tint:); public mutating func mentionableEveryShape(where:) }
public enum MentionResolution: Hashable { case live(MentionAppearance), missing, unavailable }
extension Registry {
    public func mentionAppearance(of shape: AnyShapeRecord) -> MentionAppearance?
    public func mentionResolution(of target: ShapeID, lookup: (ShapeID) -> AnyShapeRecord?) -> MentionResolution
}

// MentionState.swift (F): design §2.5, §7
@MainActor @Observable public final class MentionState {
    public func mentioners(of target: ShapeID) -> [ShapeID]; public func mentions(in shape: ShapeID) -> [ShapeID]
    public func resolve(_ target: ShapeID) -> MentionResolution
    public func plainText<S>(_ text: ScopedMentionText<S>) -> String
    public func rowsAffected(by changes: ChangeSet) -> Set<ShapeID>
    public func follow(_ target: ShapeID)                    // next turn of editor.scheduler: editor.goTo([target])
    public func hover(_ target: ShapeID); public func endHover(_ target: ShapeID)
    public func observe(_ targets: Set<ShapeID>, _ changed: @escaping @MainActor (Set<ShapeID>) -> Void) -> MentionObservation
    public func labelRevision(of target: ShapeID) -> Int
    public func candidates<S: MentionScope>(matching query: String, in scope: S.Type, for owner: ShapeID?) -> MentionCandidates
    public func didPick(_ target: ShapeID)
    public var registry: Registry { get }
}
public final class MentionObservation { public func cancel() }      // cancels on deinit too
public struct MentionCandidate: Hashable { public let id: ShapeID; public let appearance: MentionAppearance; public let isReadOnly: Bool; public let matched: [Range<Int>] }  // matched: Character offsets in the label
public struct MentionCandidates: Hashable { public var recent: [MentionCandidate]; public var nearby: [MentionCandidate]; public var matches: [MentionCandidate] }
extension MentionState: EditorService {}

// MentionMatching.swift (F): Amendment 1's fuzzy table
public struct MentionMatch: Hashable, Sendable { public let score: Int; public let matched: [Range<Int>] }
public enum MentionMatcher { public static func match(_ query: String, in label: String) -> MentionMatch? }   // plus a prepared fast path for the catalog

// MentionRows.swift (F)
public enum MentionRows { @MainActor public static func affected(_ changes: ChangeSet, _ context: ContentsContext) -> Set<ShapeID> }
extension ContentsContext { public func plainText<S>(_ text: ScopedMentionText<S>) -> String }

// MentionTextStyle.swift, MentionPill.swift (F): design §1.5, §2.4, §6.2
public enum MentionSurface: Hashable, Sendable { case shape, neutral }
@MainActor public struct MentionTextStyle: @MainActor Hashable {
    public init(font: NSFont, color: NSColor, lineHeight: CGFloat? = nil, surface: MentionSurface = .shape)
    public var attributes: [NSAttributedString.Key: Any] { get }     // font, color, fixed line height
    /// Text runs with `attributes`, each mention one MentionAttachment character (U+FFFC) with them.
    public func attributedString<S>(_ text: ScopedMentionText<S>, resolve: (ShapeID) -> MentionResolution) -> NSAttributedString
    /// The inverse, canonical: each attachment a mention with its live label, else its stored one.
    public static func mentionText<S>(from string: NSAttributedString) -> ScopedMentionText<S>
}
@MainActor public final class MentionAttachment: NSTextAttachment {
    public let target: ShapeID; public private(set) var storedLabel: String; public private(set) var resolution: MentionResolution
    public var isSelected: Bool                                // the selected look (text views)
    public func update(_ resolution: MentionResolution)       // a live label changed: new image and bounds
}

// MentionDrawing.swift (C; F stubs: drawMentionText draws the attributed string plainly, no memo; mentionPills returns [])
@MainActor public struct MentionTextPlacement { public init<S>(_ text: ScopedMentionText<S>, in box: CGRect, style: MentionTextStyle, lines: Int? = nil) }
public enum MentionTexts {}                                   // KeyedExtensionPoint, one per kind
extension ShapeRegistrar { public mutating func mentionText(_ place: @escaping @MainActor (ShapeRecord<Definition.Props>) -> [MentionTextPlacement]) }
extension PluginRegistrar { public mutating func mentionText<P: ShapeProps>(_: P.Type, _ place: @escaping @MainActor (ShapeRecord<P>) -> [MentionTextPlacement]) }
extension RenderContext { public func drawMentionText(_ placement: MentionTextPlacement) }
public struct MentionPillFrame: Hashable { public let target: ShapeID; public let frame: CGRect; public let isLive: Bool }   // world units
extension CanvasEditor { public func mentionPills(of shape: ShapeID) -> [MentionPillFrame] }

// MentionFaces.swift (C; F stubs as a no-op)
func registerMentionFaces(into registrar: inout PluginRegistrar)

// MentionTextView.swift (E; F stubs: a plain NSTextView subclass showing attributedString(...) and reading mentionText back)
@MainActor public final class MentionTextView<Scope: MentionScope>: NSTextView {
    public init(frame: CGRect, text: ScopedMentionText<Scope>, style: MentionTextStyle, owner: ShapeID?, mentions: MentionState?)
    public override init(frame: CGRect, textContainer: NSTextContainer?)
    public required init?(coder: NSCoder)
    public var mentionText: ScopedMentionText<Scope> { get }
    @discardableResult public func selectPill(at point: CGPoint) -> Bool   // view coordinates; selects that pill's character
    public var picker: MentionPicker? { get }                               // the open picker, nil when closed
}
// MentionPicker.swift (E; F stubs an empty final class)
@MainActor public final class MentionPicker {}
```

## Rules for every agent

- Work only in your own worktree; commit on your own branch; never touch `main`, never push, never
  merge into main. Parallel agents create their worktree from the `mentions` branch:
  `git -C /Users/zekenie/code/native-canvas worktree add /Users/zekenie/code/native-canvas/.claude/worktrees/mentions-<area> -b mentions-<area> mentions`.
- Build and test from your worktree: `./build.sh audit`, `TEST_FILTER=… ./test.sh`, `./test.sh`.
  If the build says "this SDK is not supported by the compiler", prefix
  `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`. Swift 6, `-warnings-as-errors`.
  Other agents build in parallel, so builds are slow; don't kill other processes.
- Before you finish: the audit passes, your tests pass, and every test executable that your change
  can affect passes (run `./test.sh` whole at the end). Commit with a message that leads with intent
  (why, what was decided, what was rejected), ending with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- Screen capture isn't permitted. Nothing goes on screen: unshown windows only; the picker never
  orders in while its parent window isn't visible. Never touch the user's pasteboard
  (`NSPasteboard.withUniqueName()`, `releaseGlobally()`).
- UI copy is quiet: terse, no instructions, each thing said once.
- Comments and docs read like the surrounding code: plain sentences saying what is and why.
