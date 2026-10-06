import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import SlashCommands
import TestKit
import TextEditing

// Fixtures only: CanvasTesting's boxes, discs and cards (a card holds text, and is edited), and
// chores with their added `Flagged`, so every test here shows SlashCommands knows no real kind.

/// What the fixture commands that `perform` did, in order, and what the rule of the one that takes a
/// shape was asked.
@MainActor final class CommandLog {
    var runs: [String] = []
    /// What `stack`'s rule was asked, in order (and `park`'s).
    var asked: [Asked] = []
    /// How many times `park`'s kinds were asked of the registry.
    var kindsAsked = 0

    /// A question to a rule: the shape, the shape the line is on, and the editor it was given.
    struct Asked: Equatable {
        let target: ShapeID
        let owner: ShapeID
        let editor: ObjectIdentifier
    }
}

/// Commands for cards, to type: `grow` and `width` edit the card's frame (one takes nothing, the
/// other a number), `log` and `ping` perform (the first takes anything and logs it), `stack` takes one
/// shape, a disc and no other, and logs it (and what its rule was asked), `wide` is offered only while
/// the card is wide, and `any` accepts whatever follows, even nothing.
struct CardCommandsPlugin: CanvasPlugin {
    let log: CommandLog
    var id: PluginID { "card-commands" }

    func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.slashCommands(Card.self) {
            SlashCommand("grow") { card, _ in card.frame.size.width += 10 }
            SlashCommand("width", argument: "points") { card, arguments in
                card.frame.size.width = Double(arguments.text) ?? card.frame.width
            }
            SlashCommand("log", argument: "text") { _, arguments, _ in log.runs.append("log \(arguments.text)") }
            SlashCommand("ping") { _, _, _ in log.runs.append("ping") }
            SlashCommand("stack", shapes: { target, owner, editor in
                log.asked.append(CommandLog.Asked(target: target, owner: owner, editor: ObjectIdentifier(editor)))
                return editor.document[target]?.kind == Disc.kind
            }) { _, arguments, _ in log.runs.append("stack \(arguments.text)") }
            SlashCommand("wide", when: { $0.frame.width >= 110 }) { card, _ in card.frame.size.width = 100 }
            SlashCommand("any", argument: "anything", accepts: { _ in true }) { _, arguments, _ in
                log.runs.append("any \(arguments.text.debugDescription)")
            }
        }
    }
}

/// A command for cards that takes one shape of the kinds that hold shapes or own boards (a corral, a
/// pocket), whatever its rule would say: `park`'s rule admits every shape but the card itself, so
/// it's the kinds that refuse a box, a disc or another card. The log keeps what its rule was asked
/// and how many times its kinds were. A list with it has the corrals and pockets (`CorralsPlugin()`
/// and `PocketsPlugin()`).
struct ParkCommandPlugin: CanvasPlugin {
    let log: CommandLog
    var id: PluginID { "park-command" }

    func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.slashCommands(Card.self) {
            SlashCommand("park", kinds: { registry in
                log.kindsAsked += 1
                return registry.containingKinds.union(registry.boardOwningKinds)
            }, shapes: { target, owner, editor in
                log.asked.append(CommandLog.Asked(target: target, owner: owner, editor: ObjectIdentifier(editor)))
                return target != owner
            }) { _, arguments, _ in log.runs.append("park \(arguments.text)") }
        }
    }
}

/// A command for cards that reads their text: `filled` (widening the card by 5) is offered only
/// while the text isn't blank, so a text view that takes its line out first leaves it nothing to read.
struct FilledCommandPlugin: CanvasPlugin {
    var id: PluginID { "filled-command" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.slashCommands(Card.self) {
            SlashCommand("filled", when: { !$0.text.allSatisfy(\.isWhitespace) }) { card, _ in card.frame.size.width += 5 }
        }
    }
}

/// What a mention text view reads after a command's name, as a test says a person picked it: `runs`
/// once anything is typed there (the pills of the line), nothing before. `SlashSession`'s `arguments`.
@MainActor final class PickedShapes {
    var runs: [SlashArguments.Run] = []

    func read(_ range: NSRange) -> SlashArguments {
        range.length == 0 ? SlashArguments([]) : SlashArguments(runs)
    }
}

/// The standard list: the fixtures, the cards, the chores, the slash commands, then `more`.
@MainActor func slashPlugins(_ more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [FixturesPlugin(), CardsPlugin(), ChoresPlugin(), SlashCommandsPlugin()] + more
}

@MainActor func slashHarness(_ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: slashPlugins(more))
}

/// The text view of these tests: an `EditingTextView` that forwards to `SlashCommandTyping` as a
/// mention text view does (what's typed, every change to the text and to the caret, each key
/// first), and shows its list as its own.
@MainActor
final class SlashTextView: EditingTextView {
    private(set) var slashCommands: SlashCommandTyping?
    /// Between `shouldChangeText` and `didChangeText`: the selection moving then is the edit's.
    private var isChangingText = false

    init(frame: CGRect, owner: ShapeID, commands: SlashCommandState, arguments: (@MainActor (NSRange) -> SlashArguments)? = nil) {
        super.init(frame: frame)
        isRichText = false
        allowsUndo = true
        slashCommands = SlashCommandTyping(over: self, owner: owner, commands: commands, arguments: arguments)
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var caretListWindow: CaretListWindow? { slashCommands?.window }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let should = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if should { isChangingText = true }
        return should
    }

    override func didChangeText() {
        isChangingText = false
        super.didChangeText()
        slashCommands?.didChange(isEdit: true)
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !isChangingText { slashCommands?.didChange(isEdit: false) }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if !wasComposing, !hasMarkedText() { slashCommands?.didType(typed) }
    }

    override func keyDown(with event: NSEvent) {
        if slashCommands?.takesKey(event) == true { return }
        super.keyDown(with: event)
    }
}

/// The host's side of the text view: it writes the text to the card in the editing session, as an
/// editor does, and counts what it heard.
@MainActor
final class SlashHost: NSObject, NSTextViewDelegate {
    private let context: EditContext<Card>
    weak var view: NSTextView?
    private(set) var changes = 0
    private(set) var commits = 0

    init(context: EditContext<Card>) { self.context = context }

    func textDidChange(_ notification: Notification) {
        changes += 1
        guard let text = view?.string else { return }
        context.update { if $0.text != text { $0.text = text } }
    }

    /// What a box's `onCommit` would do.
    func commit() { commits += 1 }
}

/// A card being edited: its text view in an unshown window, the keyboard in it, the caret at the
/// end of its text. The card's text on the board is what the host last wrote.
@MainActor
final class SlashSession {
    let h: EditorHarness
    let card: ShapeID
    let log: CommandLog
    let window: NSWindow
    let view: SlashTextView
    let host: SlashHost

    /// `offering` false leaves the card commandless (`CardCommandsPlugin` isn't installed).
    init(_ text: String = "", offering: Bool = true, plugins more: [any CanvasPlugin] = [],
         arguments: (@MainActor (NSRange) -> SlashArguments)? = nil) throws {
        log = CommandLog()
        h = try slashHarness((offering ? [CardCommandsPlugin(log: log)] : []) + more)
        card = h.editor.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60), text: text))
        expect(h.editor.beginEditing(card))
        let field = try require(h.editor.makeEditingView()?.view as? CardField)
        view = SlashTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), owner: card, commands: try require(h.editor.slashCommands),
                             arguments: arguments)
        host = SlashHost(context: field.context)
        host.view = view
        view.delegate = host
        view.string = text
        window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.makeFirstResponder(view)
        view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
    }

    var string: String { view.string }
    var caret: NSRange { view.selectedRange() }
    var cardText: String { h.editor.document[card]?.typed(as: Card.self)?.props.text ?? "" }
    var width: CGFloat { h.editor.document[card]?.typed(as: Card.self)?.props.frame.width ?? 0 }
    var list: SlashCommandPicker? { view.slashCommands?.picker }
    var rows: [String] { list?.rows.map(Self.describe) ?? [] }
    var listed: [String] { list?.listed.map(\.name) ?? [] }
    var highlighted: String? { list?.highlightedCommand?.name }

    /// Puts `text` in the view with the caret at `caret`, as the person had it: nothing is heard.
    func set(_ text: String, caret: Int? = nil) {
        view.string = text
        view.setSelectedRange(NSRange(location: caret ?? (text as NSString).length, length: 0))
    }

    func type(_ text: String) { window.type(text) }
    func down() { window.press("\u{F701}", code: 125, modifiers: [.numericPad, .function]) }
    func up() { window.press("\u{F700}", code: 126, modifiers: [.numericPad, .function]) }
    func left() { window.press("\u{F702}", code: 123, modifiers: [.numericPad, .function]) }
    func tab() { window.press("\t", code: 48) }
    func returnKey(_ modifiers: NSEvent.ModifierFlags = []) { window.press("\r", code: 36, modifiers: modifiers) }

    /// Types a line break: Return with no list open and no command line, as a person ends a line.
    func newLine() { returnKey() }

    private static func describe(_ row: CaretListRow) -> String {
        switch row {
        case .header(let words): "# \(words)"
        case .empty(let words): "- \(words)"
        case .item(let item): item.detail.map { "\(item.title) (\($0))" } ?? item.title
        }
    }
}
