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
    /// How many times the choice commands were asked for their rows.
    var choicesAsked = 0

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

/// Commands for cards that take one choice: `pick` lists alpha, beta (preferred, its own step) and
/// gamma (a group of its own); `pickElse` lists `phone`, `one` and `red panda` and offers a row for any
/// text but "nope" that no row is titled; `pickNone` lists nothing; `pickWide` is offered only while the
/// card is wide.
/// A pick widens the card by one, so it is a step of the board, and is logged.
struct ChoicePlugin: CanvasPlugin {
    let log: CommandLog
    var id: PluginID { "choices" }

    func register(into registrar: inout PluginRegistrar) {
        let log = log
        let widen: @MainActor (ShapeID, SlashChoice, CanvasEditor) -> Void = { id, choice, editor in
            log.runs.append("pick \(choice.id)")
            editor.transact { $0.update(id, as: Card.self) { $0.props.frame.size.width += 1 } }
        }
        registrar.slashCommands(Card.self) {
            SlashCommand("pick", argument: "item", choices: { _, _ in
                log.choicesAsked += 1
                return [SlashChoice("alpha", title: "Alpha"),
                        SlashChoice("beta", title: "Beta", step: "Pick Beta", isPreferred: true),
                        SlashChoice("gamma", title: "Gamma", symbol: "star", detail: "last", group: 1)]
            }, perform: widen)
            SlashCommand("pick-else", argument: "item", choices: { _, _ in
                log.choicesAsked += 1
                return [SlashChoice("phone", title: "Phone"), SlashChoice("one", title: "One"), SlashChoice("red-panda", title: "Red Panda")]
            }, otherwise: { typed, _, _ in
                typed == "nope" ? nil : SlashChoice("else:\(typed)", title: "Else \(typed)", step: "Make Else")
            }, perform: widen)
            SlashCommand("pick-none", argument: "item", choices: { _, _ in [] }, perform: widen)
            SlashCommand("pick-chips", argument: "item", choices: { _, _ in
                [SlashChoice("red", title: "Red", symbol: "star", chip: .systemRed), SlashChoice("plain", title: "Plain", symbol: "star")]
            }, perform: widen)
            SlashCommand("pick-wide", argument: "item", when: { $0.frame.width >= 110 }, choices: { _, _ in
                [SlashChoice("wide", title: "Wide")]
            }, perform: widen)
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

/// What the target fixtures' commands did, in order.
@MainActor final class Reached {
    var runs: [String] = []
    /// The shapes each run of `heap` and `tag` and each pick of `pick-all` was handed.
    var handed: [[ShapeID]] = []
    /// The shapes `pick-all`'s rows were made for, each time they were asked.
    var rowsAskedFor: [[ShapeID]] = []
}

/// Commands that act on several shapes, beside `CardCommandsPlugin`'s:
/// - `heap`, cards', together: handed every card it acts on, at once;
/// - `nudge-each`, cards', a perform on each: run once a card, in one step;
/// - `turn-on`, cards' own, an edit (2 points wider), beside the lamp's own `turn-on`: one name, two commands;
/// - `pick-two`, cards' own and lamps' own, a choice together: one name that is two choice commands;
/// - `pick-all`, cards', a choice together, its rows made for the cards it's handed;
/// - `tag`, every box's (a scope's), together: what a mixed selection has in common;
/// - `spread`, declared ("Spread Out", 5 points wider), whose rule needs a card 100 wide that can change,
///   typed as `/spread` and as `/spread-try`, a try;
/// - `thaw`, declared ("Thaw"), on every frozen shape, which it unfreezes.
struct TargetCommandsPlugin: CanvasPlugin {
    let log: Reached
    var id: PluginID { "target-commands" }

    func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.slashCommands(Card.self) {
            SlashCommand.together("heap") { ids, _, _ in
                log.runs.append("heap")
                log.handed.append(ids)
            }
            SlashCommand("nudge-each", reach: .each) { id, _, editor in
                log.runs.append("nudge")
                editor.transact { $0.update(id, as: Card.self) { $0.props.frame.origin.x += 1 } }
            }
            SlashCommand("turn-on") { card, _ in card.frame.size.width += 2 }
            SlashCommand.together("pick-two", argument: "item", choices: { _, _ in [SlashChoice("x", title: "X")] }) { _, _, _ in }
            SlashCommand.together("pick-all", argument: "count", choices: { owners, _ in
                log.rowsAskedFor.append(owners)
                return [SlashChoice("all", title: "All \(owners.count)", step: "Pick All")]
            }) { owners, _, editor in
                log.handed.append(owners)
                editor.transact { transaction in
                    for id in owners { transaction.update(id, as: Card.self) { $0.props.frame.size.width += 1 } }
                }
            }
            SlashCommand("spread", command: "spread")
            SlashCommand("spread-try", command: "spread", tries: true)
        }
        registrar.slashCommands(Lamp.self) {
            SlashCommand.together("pick-two", argument: "item", choices: { _, _ in [SlashChoice("y", title: "Y")] }) { _, _, _ in }
        }
        registrar.forShapes(adopting: .box) { boxes in
            boxes.slashCommands {
                SlashCommand.together("tag") { ids, _, _ in
                    log.runs.append("tag")
                    log.handed.append(ids)
                }
            }
        }
        registrar.command("spread", title: "Spread Out", isEnabled: { subject in
            subject.shapes.contains { !subject.editor.isReadOnly($0) && (subject.editor.document[$0]?.box?.width ?? 0) >= 100 }
        }) { subject in
            subject.editor.transact { transaction in
                for id in subject.shapes { transaction.update(id, as: Card.self) { $0.props.frame.size.width += 5 } }
            }
        }
        registrar.command("thaw", title: "Thaw", isEnabled: { subject in
            subject.shapes.contains { subject.editor.document[$0]?[Frozen.self] == true }
        }) { subject in subject.editor.freeze(subject.shapes, false) }
        registrar.forShapes(holding: Frozen.self) { frozen in
            frozen.slashCommands { SlashCommand("thaw", command: "thaw", when: { $0[Frozen.self] == true }) }
        }
    }
}

/// The host's search for shapes by name, as a mention text view's would be (`SlashShapeSearch`): the shapes
/// named here whose label holds what's typed (case aside), in this order, each said to be a disc, counting
/// in `asked` each time it's asked.
@MainActor func namedShapes(_ named: [(id: ShapeID, label: String)], asked: SearchCount? = nil) -> SlashShapeSearch {
    { query in
        asked?.count += 1
        return named.compactMap { id, label in
            let folded = label.lowercased()
            guard let found = folded.range(of: query.lowercased()) else { return nil }
            let start = folded.distance(from: folded.startIndex, to: found.lowerBound)
            return SlashShapeMatch(id, label: label, matched: [start..<start + query.count], detail: "Disc", spoken: "a disc")
        }
    }
}

/// How many times a host's search was asked.
@MainActor final class SearchCount {
    var count = 0
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

    init(frame: CGRect, owner: ShapeID, commands: SlashCommandState, arguments: (@MainActor (NSRange) -> SlashArguments)? = nil,
         shapes: SlashShapeSearch? = nil) {
        super.init(frame: frame)
        isRichText = false
        allowsUndo = true
        slashCommands = SlashCommandTyping(over: self, owner: owner, commands: commands, arguments: arguments, shapes: shapes)
    }

    /// A line typed for any target (the shapes selected, as the command bar's field types for them),
    /// writing to no shape.
    init(frame: CGRect, target: SlashTarget, commands: SlashCommandState, shapes: SlashShapeSearch? = nil, takesShapes: Bool = true) {
        super.init(frame: frame)
        isRichText = false
        allowsUndo = true
        slashCommands = SlashCommandTyping(over: self, target: target, commands: commands, shapes: shapes, takesShapes: takesShapes)
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

    /// `offering` false leaves the card commandless (`CardCommandsPlugin` isn't installed). `board` puts
    /// shapes on the board before the card is edited, and gives the host's shape search (`shapes`) if any.
    init(_ text: String = "", offering: Bool = true, plugins more: [any CanvasPlugin] = [], log: CommandLog? = nil,
         arguments: (@MainActor (NSRange) -> SlashArguments)? = nil,
         board: (@MainActor (CanvasEditor) -> SlashShapeSearch?)? = nil) throws {
        self.log = log ?? CommandLog()
        h = try slashHarness((offering ? [CardCommandsPlugin(log: self.log)] : []) + more)
        let shapes = board?(h.editor)
        card = h.editor.add(Card(CGRect(x: 0, y: 0, width: 100, height: 60), text: text))
        expect(h.editor.beginEditing(card))
        let field = try require(h.editor.makeEditingView()?.view as? CardField)
        view = SlashTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 200), owner: card, commands: try require(h.editor.slashCommands),
                             arguments: arguments, shapes: shapes)
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
    var choiceList: SlashChoicePicker? { view.slashCommands?.choices }
    /// The choices' rows, a line before a row it sets off written `—`.
    var choiceRows: [String] {
        choiceList?.rows.map { row in
            switch row {
            case .header(let words): "# \(words)"
            case .empty(let words): "- \(words)"
            case .item(let item): (item.separated ? "— " : "") + item.title
            }
        } ?? []
    }
    var highlightedChoice: String? { choiceList?.highlightedChoice?.id }

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

/// What `AskPlugin`'s command was started with, the answers a test hands it, and how many of its tasks were
/// cancelled before they answered.
@MainActor final class AskLog {
    /// Each start: the target and what was typed after the name.
    var asked: [(target: SlashTarget, arguments: SlashArguments)] = []
    /// How many started tasks were cancelled before a test answered them.
    var cancelled = 0
    private var waiting: [Int: CheckedContinuation<SlashAnswer, Never>] = [:]
    private var stopped: Set<Int> = []
    private var started = 0

    /// How many tasks wait for an answer.
    var waitingCount: Int { waiting.count }

    /// Answers the task started first of those that wait.
    func answer(_ answer: SlashAnswer) {
        guard let first = waiting.keys.min(), let continuation = waiting.removeValue(forKey: first) else { return }
        continuation.resume(returning: answer)
    }

    /// A task that waits for `answer(_:)`, or for its cancellation, which answers it done.
    func task() -> Task<SlashAnswer, Never> {
        started += 1
        let id = started
        return Task { @MainActor [weak self] in
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    guard let self, !self.stopped.contains(id) else { return continuation.resume(returning: .done) }
                    self.waiting[id] = continuation
                }
            } onCancel: {
                MainActor.assumeIsolated { self?.stop(id) }
            }
        }
    }

    private func stop(_ id: Int) {
        stopped.insert(id)
        guard let continuation = waiting.removeValue(forKey: id) else { return }
        cancelled += 1
        continuation.resume(returning: .done)
    }
}

/// A command about the command bar's target as a whole: `ask`, which takes words, says `Asking` while it waits,
/// and is offered on several shapes or on every shape on the board, never on one; its task waits for the answer a
/// test hands it (`AskLog`).
struct AskPlugin: CanvasPlugin {
    let log: AskLog
    var id: PluginID { "ask-commands" }

    func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.selectionSlashCommand(SelectionSlashCommand("ask", argument: "words", waiting: "Asking", when: { target, _ in
            if case .selection(let ids) = target { return ids.count > 1 }
            return true
        }) { target, arguments, _ in
            log.asked.append((target, arguments))
            return log.task()
        })
    }
}

/// What `NowPlugin`'s command ran with, and whether the bar was still open as it ran.
@MainActor final class NowLog {
    var ran: [(target: SlashTarget, arguments: SlashArguments, barOpen: Bool)] = []
}

/// `stamp`, a command about the bar's target that runs at once (`SelectionSlashCommand.atOnce`): offered
/// with nothing selected, on an empty board too, never for a selection; it takes words and puts a disc down
/// each run, so it commits.
struct NowPlugin: CanvasPlugin {
    let log: NowLog
    var id: PluginID { "now-commands" }

    func register(into registrar: inout PluginRegistrar) {
        let log = log
        registrar.selectionSlashCommand(.atOnce("stamp", argument: "words", when: { target, _ in
            if case .everything = target { return true }
            return false
        }) { target, arguments, editor in
            log.ran.append((target, arguments, editor.slashBar?.isOpen == true))
            editor.transact { $0.insert(AnyShapeRecord(ShapeRecord(Disc(CGRect(x: 0, y: 0, width: 10, height: 10))))) }
        })
    }
}
