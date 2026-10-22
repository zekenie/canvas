# Slash commands: the plan

Repo: the git worktree `/Users/zekenie/code/native-canvas/.claude/worktrees/slash-commands-plugin-daa9be`
(branch `claude/slash-commands-plugin-daa9be`). Never touch the main checkout at
`~/code/native-canvas`. Read `CLAUDE.md` first (it's huge: skim its build/test section and the
Mentions, DetailPanel and ContextMenus bullets), then `docs/plugin-system.md`'s "A horizontal
plugin", "Context menus" and "Mentions" sections.

## What the owner asked for (their words, paraphrased tightly)

A new horizontal plugin: slash commands. Used in multiple text surfaces, just like mentions ("in
fact, they're a lot like mentions"). Plugins register commands, conditionally, the way they register
conditional detail-panel sections and context-menu items. The command's name autocompletes. The
whole line is evaluated on newline (Return). Slash commands are available only when the caret is at
the beginning of a new line; in the middle of a line a slash is just a slash. After it's evaluated,
the command's text goes away (it doesn't remain in the note); it just takes action.

Hypothetical commands, NONE of which is part of this build: `/turn-into type`, `/move-near
@other-shape`, `/set-type some-typename`, `/set-title foobar`, `/lock`, `/move-into
@some-subboard-or-frame`. So nothing ships a command: the plugin ships, offers nothing, and "/"
stays a slash in the app until some plugin registers a command. Fixture commands in tests prove the
API (as `MentionTextArea` had no shipped user and fixtures held it).

## Decisions (made; don't re-litigate)

1. **Module graph.** `SlashCommands` is a horizontal on `Canvas` and `DetailPanel` (the caret list
   and `DetailTextView`). It knows nothing of mentions: a command's arguments are runs of text and
   shapes. `Mentions` builds on `SlashCommands`: `MentionTextView`, the app's text view (a note's
   editor, a schema card's description editor, the panel's `MentionTextArea`), hosts slash
   commands, as it hosts the `@` picker, and turns its pills into shape arguments. So every surface
   where mentions are typed takes slash commands. Mentions contributes nothing to SlashCommands'
   point, so a list with Mentions doesn't need `SlashCommandsPlugin()`; without it a mention text
   view has no slash commands.
2. **Registration mirrors ContextMenus** (`Sources/ContextMenus/ContextMenus.swift`,
   `MenuItems.swift`): a keyed point `ShapeSlashCommands`; `SlashCommand<Value>` items collected by
   a result builder; sugar `x.slashCommands { }` (a kind's own, over its props), `x.slashCommands(of:
   P.self) { }` (over an added property's value, on the kind's shapes that have one),
   `registrar.slashCommands(P.self) { }` (bridges), `registrar.slashCommands(of: P.self) { }` (an
   added property, every shape that has one), `registrar.slashCommandsForEveryShape(where:) { }`
   (over `AnyShapeRecord`; `where` gets a `SlashCommandKind`, with `holds(P.self)`, as
   Adornments' `AdornableKind` does, so a feature's every-shape command can go only on kinds that
   opted into it). `when:` per shape. A kind's own command takes the place of an every-shape one of
   the same name. Two claims to one name for one target are a `conflict`.
3. **Where the list opens.** `/` typed (not pasted, not an undo, not mid-composition) on an
   **empty** line: at the text's start or right after a line break, with nothing after it on its
   line. Not at the start of a line that already has text (Return with the list open could run a
   command and take that text with the line), and never mid-line. Only while the view is editable,
   no other caret list is open, and the shape offers at least one command (none offered: no list,
   a slash is a slash).
4. **The list** is the app's one caret list (DetailPanel's `CaretList` in a `CaretListWindow`),
   anchored under the `/`. Rows: each offered command's name (no "/"), what's typed matched in
   semibold, its argument hint as the detail ("title", "@shape"), no symbol, no header. Empty query:
   every offered command in offered order. Else ranked with `CaretListMatcher.matches` (best tier
   first, then offered order); nothing matches: one empty row, "No matches". VoiceOver label
   "Commands". Metrics: width 240, row height 24, 8 rows shown, 4 below the anchor.
   While it's open the text's substitutions (spelling correction, text replacement, quotes, dashes)
   are off and put back as it closes, as Mentions' picker has it.
5. **What's typed after `/` is the query** (MentionPicker's model, `Sources/Mentions/MentionPicker.swift`):
   it closes when the caret leaves it (before or at the `/`, past what was typed, a selection), the
   `/` is deleted, what's typed holds anything that can't be in a name (whitespace ends the name,
   a line break, a pill's U+FFFC, punctuation), or it's past 40 characters. Name characters: ASCII
   letters (any case, matched folded), digits and `-`.
6. **Keys while it's open** are every caret list's (DetailTextView routes them): ↑ ↓ ⌃P ⌃N Page
   Up/Down move; Tab picks; Escape, ⌘. close. A pick (Tab, or a click on a row) **completes**:
   replaces `/` and the name typed with `/` + the command's name, plus a space if it takes an
   argument (unless whitespace follows), caret after; one step of the text's undo. **Return** is
   the slash list's own (intercepted before DetailTextView's routing): if the highlighted command
   accepts an empty rest of line (`accepts(SlashArguments([]))`), it **runs it at once** (the line
   goes, below); otherwise it completes, as Tab does, so its argument can be typed. With "No
   matches" (nothing highlighted) Return isn't the list's: it's a new line, which closes the list.
7. **Return on a command line** (list closed): the caret (an empty selection) is on a line whose
   text starts with `/`, after that `/`; then a name, ended by whitespace or the line's end; the
   shape offers a command of that name (folded to lowercase) now; and the command accepts what
   follows the name (trimmed; `SlashArguments`). Then: the line's text (from its `/` to the line's
   end, not its line break) is taken out of the text as an edit of the person's (undoable, heard by
   the host), the caret stays at the line's start, on the now-empty line, and the command runs.
   Anything else (not a command, a command not offered, arguments it doesn't accept, a selection,
   the caret before the `/`, ⇧↩/⌥↩/⌘↩, marked text) is Return as ever: a new line, or a box's
   commit. So `/lock foo` (a command without an argument given one) and `/set-title` (given none)
   stay text.
8. **Accepts.** `SlashCommand(_:argument:when:accepts:…)`: `argument` is the hint ("title",
   "@shape") and says it takes one. Default `accepts`: no `argument` → only an empty rest;
   an `argument` → a non-empty rest. `accepts:` given replaces the default entirely.
9. **Running.** Synchronously, right after the line is taken out (taking it out first matters: a
   command that makes the shape read-only, `/lock`, would refuse the text's write after it). The
   run is one undo step of its own, `editor.undoHistory.group(title) { … }`, `title` the name in
   words, each capitalized ("set-title" → "Set Title"). While a shape is being edited, the line's
   removal joins the editing session's step and the command closes it, as any other commit does
   (UndoHistory), so the command is a step between the typing before and after. The text's own
   undo (⌘Z while typing) brings the line's text back, and doesn't undo the command: text undo is
   the text's. A command that ends editing (a lock, a shape gone) ends it as the core already does.
   Two forms, as MenuItem's: `edit: { value, arguments in … }` edits the shape's live value in one
   transaction; `perform: { id, arguments, editor in … }` for what editing can't do.
10. **Names**: words of lowercase ASCII letters and digits joined by single hyphens (`set-title`,
    `move-into`, `h2`). `ShapeSlashCommands.check` refuses any other with `RegistryError.invalid`.
11. **The service** `SlashCommandState` (`editor.slashCommands`) keeps nothing per shape: each
    kind's commands gathered once (registry is frozen); `boardDidChange` overridden with nothing (as
    ContextMenus' state does; CompositionTests' BoardsTests hold every shipped service to working
    out no change set on a switch).
12. **Shipped**: `SlashCommandsPlugin()` goes in `ShippedPlugins.plugins(pasteboard:model:)` right
    after `ContextMenusPlugin()`. Its report line is
    `slash-commands       service SlashCommandState` (the id column is 21 wide).

## The API (SlashCommands module, `Sources/SlashCommands/`)

Names are fixed; signatures may be adjusted only if the compiler forces it (say so in the report).

```swift
extension PluginID { public static let slashCommands: PluginID = "slash-commands" }

public struct SlashCommandsPlugin: CanvasPlugin {          // registers SlashCommandState only
    public init()
    public var id: PluginID { .slashCommands }
}

/// What's typed on a command's line after its name: text, and the shapes it names (a mention
/// text's pills), in order, with whitespace at both ends trimmed and adjacent text runs merged.
public struct SlashArguments: Equatable, Sendable, ExpressibleByStringLiteral {
    public enum Run: Equatable, Sendable {
        case text(String)
        case shape(ShapeID, label: String)     // a shape the text names, and the name it shows
    }
    public let runs: [Run]
    public init(_ runs: [Run])
    public init(_ text: String)                // plain text
    public init(stringLiteral: String)
    public var isEmpty: Bool                   // no runs once trimmed
    public var text: String                    // as text, each shape "@" and its label: "near @Groceries"
    public var shapes: [ShapeID]               // the shapes named, in order, each once
}

/// A kind, as `slashCommandsForEveryShape(where:)` sees it.
@MainActor public struct SlashCommandKind {
    public let kind: ShapeKind
    public let definition: any ShapeDefinition
    public let registry: Registry
    public func holds<P: ShapeProperty>(_: P.Type) -> Bool   // registry.properties(for: kind).contains(P.key)
}

/// One command a shape offers, typed as `/name` on a line of its text, over `Value`.
public struct SlashCommand<Value> {
    public init(_ name: String, argument: String? = nil,
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                edit: @escaping @MainActor (inout Value, SlashArguments) -> Void)
    public init(_ name: String, argument: String? = nil,
                when isOffered: @escaping @MainActor (Value) -> Bool = { _ in true },
                accepts: (@MainActor (SlashArguments) -> Bool)? = nil,
                perform: @escaping @MainActor (ShapeID, SlashArguments, CanvasEditor) -> Void)
}

@resultBuilder public enum SlashCommandBuilder<Value> { … }   // as MenuBuilder: expression, block, optional, either, array

public enum ShapeSlashCommands {}                 // KeyedExtensionPoint, owner .slashCommands
// uniqueKeys: one per (target, name); summary "/flip /grow → box", "/rename → every shape";
// check: every name `SlashCommandLine.isName`, else .invalid(point: "ShapeSlashCommands",
//   reason: "<plugin> offers /<name>, which can't be typed as a command's name: lowercase letters and digits, words joined by hyphens")
@MainActor public struct SlashCommandContribution { … }   // only the sugar makes one

extension ShapeRegistrar {
    public mutating func slashCommands(@SlashCommandBuilder<Definition.Props> _ commands: () -> [SlashCommand<Definition.Props>])
    public mutating func slashCommands<P: ShapeProperty>(of _: P.Type, @SlashCommandBuilder<P.Value> _ commands: () -> [SlashCommand<P.Value>])
}
extension PluginRegistrar {
    public mutating func slashCommands<P: ShapeProps>(_: P.Type, @SlashCommandBuilder<P> _ commands: () -> [SlashCommand<P>])
    public mutating func slashCommands<P: ShapeProperty>(of _: P.Type, @SlashCommandBuilder<P.Value> _ commands: () -> [SlashCommand<P.Value>])
    public mutating func slashCommandsForEveryShape(where offersOn: @escaping @MainActor (SlashCommandKind) -> Bool = { _ in true },
                                                    @SlashCommandBuilder<AnyShapeRecord> _ commands: () -> [SlashCommand<AnyShapeRecord>])
}

/// A command a shape offers just now.
@MainActor public struct OfferedSlashCommand {
    public let name: String
    public let argument: String?
    public var title: String                          // "Set Title": the undo step's name
    public func accepts(_ arguments: SlashArguments) -> Bool
}

@MainActor public final class SlashCommandState {     // EditorService; boardDidChange overridden with nothing
    /// What a shape offers now: its kind's own commands, then every shape's that its kind lets in
    /// (a kind's own taking the place of one of the same name), each in plugin and builder order,
    /// those whose `when` holds for the shape as it is. None for a shape that isn't on the board
    /// shown, or is kept aside.
    public func commands(for id: ShapeID) -> [OfferedSlashCommand]
    public func command(named name: String, for id: ShapeID) -> OfferedSlashCommand?   // name folded to lowercase
    /// Runs a command on a shape with what was typed after its name: one undo step named for it.
    /// False, doing nothing, for a shape that's gone or arguments the command doesn't accept.
    @discardableResult public func run(_ command: OfferedSlashCommand, on id: ShapeID, with arguments: SlashArguments) -> Bool
    /// The same, by name: false for a command the shape doesn't offer now.
    @discardableResult public func run(_ name: String, on id: ShapeID, with arguments: SlashArguments) -> Bool
}
extension CanvasEditor { public var slashCommands: SlashCommandState? }

/// A line that may be a command: its `/` where the line starts, a name, then what the command is
/// given. UTF-16 ranges, as NSString counts.
public struct SlashCommandLine: Equatable, Sendable {
    public let range: NSRange          // the line's text, from its `/` to its end, without its line break
    public let name: String            // as typed, folded to lowercase
    public let arguments: NSRange      // after the name and the whitespace after it, to the line's end, trailing whitespace left out (may be empty)
    /// The line the caret (an empty selection at `caret`) is on, if it starts with `/` and a name
    /// ended by whitespace or the line's end, and the caret is after that `/`. Line breaks: \n, \r,
    /// \r\n, U+0085, U+2028, U+2029 (NSString's getLineStart:end:contentsEnd:forRange:). Caret at
    /// the very end of text that ends in a line break is on the empty last line.
    public init?(in text: NSString, caret: Int)
    public static func isName(_ name: String) -> Bool    // ^[a-z0-9]+(-[a-z0-9]+)*$
    public static func isNameCharacter(_ c: unichar) -> Bool   // ASCII letter (any case), digit, '-'
}

/// The list a text view shows at a `/`, while it's open (headless; MentionPicker's shape).
@MainActor public final class SlashCommandPicker {
    public enum Closing: Hashable, Sendable { case caretLeft, slashDeleted, nameEnded, tooLong }
    public let location: Int                                // the `/`
    public private(set) var query: String
    public private(set) var listed: [OfferedSlashCommand]   // row for row with `list.rows`; empty when the one row is "No matches"
    public var highlighted: Int? { list.highlighted }
    public var highlightedCommand: OfferedSlashCommand?
    public var nameRange: NSRange                            // the `/` and the name typed, to the query's end: what a pick replaces
    let list: CaretList
    public init(at location: Int, offering commands: [OfferedSlashCommand])
    public static func opens(in text: NSString, at location: Int) -> Bool   // decision 3
    public func read(_ text: NSString, selection: NSRange, isEdit: Bool) -> Closing?   // decision 5
}

/// Slash commands typed in a text view (decisions 3–9). Its host, a `DetailTextView` subclass,
/// tells it what's typed and where the caret goes, asks it first about each key (`takesKey`),
/// and shows its list as its own (`caretListWindow` returns `window` while it's open).
@MainActor public final class SlashCommandTyping {
    public private(set) var picker: SlashCommandPicker?
    public var window: CaretListWindow?                     // its list's, while open
    /// `arguments` reads what's typed in a range as runs (a mention text view's pills as shapes);
    /// the default reads it as plain text.
    public init(over view: DetailTextView, owner: ShapeID, commands: SlashCommandState,
                arguments: (@MainActor (NSRange) -> SlashArguments)? = nil)
    public func didType(_ string: String)       // after insertText of typing (not while composing)
    public func didChange(isEdit: Bool)         // after a change to the text (true) or a move of the caret alone (false)
    public func takesKey(_ event: NSEvent) -> Bool   // a plain Return (keyCode 36 or 76, no ⌘⇧⌥⌃, no marked text): takesReturn()
    public func takesReturn() -> Bool           // decisions 6–7: whether it took it
    public func close()                         // its list, if open: substitutions back, window dismissed
}
```

The typing object holds its view and the state weakly. It writes the text only through the view as
an edit of the person's, exactly as `MentionTextView.replace(_:with:)` does (breakUndoCoalescing,
shouldChangeText, replaceCharacters with the view's typingAttributes, setSelectedRange, didChangeText,
breakUndoCoalescing), closing its list first, and ignores its own `didChange`/`didType` while it
writes. It opens a list only while `view.caretListWindow == nil`.

**Substitutions**: move `Substitutions` out of `MentionTextView.swift` (private struct at its end)
into DetailPanel as `public struct CaretListSubstitutions` (same four flags, `init(of:)`, `static
let off`, `apply(to:)`, doc comment: the substitutions that could rewrite what's typed for a list at
the caret, off while one's open), and use it from both Mentions' picker and the slash list.

`SlashCommandStyle` (internal `@MainActor enum`): list metrics (240, 24, 8, 4), "No matches",
"Commands", the name limit 40.

## Hosting in MentionTextView (`Sources/Mentions/MentionTextView.swift`)

- `public private(set) var slashCommands: SlashCommandTyping?`, made at the end of
  `init(frame:text:style:owner:mentions:)` when `owner` is set and the editor has the state: add
  to `MentionState` an internal `var slashCommandState: SlashCommandState? { editor.service(SlashCommandState.self) }`.
  Its `arguments` reads the attributed substring: each `MentionAttachment` run a
  `.shape(pill.target, label: pill.shownLabel)` (one per character), the rest `.text`.
- `caretListWindow`: `pickerWindow ?? slashCommands?.window`.
- `insertText`: after `super`, when it wasn't and isn't composing, `slashCommands?.didType(typed)`
  (before the `@` check, which stays as it is).
- `textDidChangeHere()`: `slashCommands?.didChange(isEdit: true)`; `setSelectedRanges`: when
  `!isChangingText`, `slashCommands?.didChange(isEdit: false)`; `undoDidChangeText`:
  `slashCommands?.didChange(isEdit: false)`.
- `keyDown(with:)` override: `if picker == nil, slashCommands?.takesKey(event) == true { return }`,
  else `super`.
- `show(_:)` and `openPicker(at:)`: `slashCommands?.close()` first.
- The class doc comment and the file header comment say it hosts slash commands.

## Tests

### SlashCommandsTests (new target, fixtures only: CanvasTesting's Box/Disc/Card, Chores' Flagged…)
- registration: every sugar form; the report's summaries; a kind's own over an every-shape command
  of the same name; `where` with `holds`; conflicts (one name twice for a kind, twice for every
  shape); invalid names refused; ownerNotInstalled; unknownKind.
- resolution: `commands(for:)` order, `when`, added-property commands only where a value is held;
  a shape not on the board / kept aside offers none.
- running: edit form (one transaction, one undo step named "Set Title" style), perform form gets id,
  arguments, editor; `run` false for unaccepted arguments / not offered; accepts defaults and custom.
- `SlashCommandLine`, `SlashArguments`, `SlashCommandPicker` (opens, read's closings, rows, ranking,
  "No matches", highlight) headlessly.
- the typing object in a `DetailTextView` subclass of the test's own that forwards as
  MentionTextView does, in an unshown NSWindow (see MentionsTests' `EditedJot` and CanvasTesting's
  `Windows.swift`: `window.type`, `press`, `pressReturn`, `pressEscape`), owner a box on an
  `EditorHarness` board: `/` on an empty line opens the list with the offered commands; mid-line, at
  the start of a non-empty line, with none offered, read-only: no list; typing narrows; a space
  closes; Escape closes; ↓ moves; Tab completes (with/without the space); Return runs a no-argument
  command from the list, the line emptied, other lines intact; Return completes a command that takes
  an argument; Return on a whole line runs it with its arguments; Return on `/unknown`, `/lock foo`,
  `/set-title` (nothing) is a new line, the text kept; ⇧↩ doesn't run; the text's undo brings the
  line back; the board's undo undoes the command's step by its name; with `onCommit` +
  `commitsOnReturn` set, Return on a command line runs it and doesn't commit, elsewhere commits.
  Substitutions off while open and back after.

### MentionsTests (a new suite in a new file, e.g. `SlashTests.swift`)
- in an `EditedJot` with `SlashCommandsPlugin()` and a fixture plugin offering jots commands: the
  list opens and runs as above in a mention text view; a pill in the line is a shape argument
  (`args.shapes == [idA]`); the `@` picker in a command line works and Return with it open picks the
  shape, not runs; then Return runs; the jot's committed text has lost the line; `caretListWindow` is
  the slash list's while it's open; `show(_:)` closes it; without `SlashCommandsPlugin()`, `/` is
  just a slash (`slashCommands == nil`).
- the panel's `MentionTextArea` with `onCommit` (Brief's Blocked By in `MentionPanel`): Return on a
  command line runs it, not commits.

### CompositionTests
- the registry report and the guide's copy of it (`docs/plugin-system.md`, the block after
  "`registry.report` prints who contributes what"), with `slash-commands       service SlashCommandState` after context-menus.
- end to end on the shipped list plus a test-only plugin offering every shape that holds
  `LockedProperty` a `/lock` that runs `editor.lock([id])` (Locking): a note edited in the app's
  canvas view (see how `mentionsShippedTests` hosts a `CanvasView`), "/lock" typed on a new line and
  Return: the note is locked, editing has ended, its text has lost the line, Undo is "Undo Lock" and
  unlocks it, the step before it is the typing.

## Docs (CLAUDE.md, docs/plugin-system.md) — in the repo's dense, exact voice
- CLAUDE.md: a bullet for SlashCommands after Mentions'; the horizontals list and "Mentions on …"
  line gain SlashCommands; Package.swift layer list; the Mentions bullet's MentionTextView part says it
  hosts slash commands; testing bullets for slash commands.
- plugin-system.md: a "## Slash commands" section after "## Mentions" (contents list too), "I want
  to…" rows, "Horizontal and vertical" sentence, the module graph table's horizontal list, the
  registry report block, the Mentions "Editing: MentionTextView" section, "Testing plugins", and
  "Not built yet" ("More of slash commands": the owner's hypothetical commands, completing
  arguments, saying why a command line doesn't run, plain-text surfaces such as arrow labels, ⌘Z
  right after a command undoing it rather than bringing the line back, a schema card's sync waiting
  while a command line is typed).
</content>
</invoke>
