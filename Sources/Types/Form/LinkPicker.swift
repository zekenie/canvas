import AppKit
import Canvas
import Mentions
import TextEditing

// The list over a pointer's field while a note is typed in to find: the notes that are the type through the
// chain, on any board the app can show, ranked as the `@` picker ranks them (Mentions' candidates, over the set
// the type's notes make: `among:`), each line the name and, when it isn't the board shown, the board's. Headless, as
// `ReferencePicker` is: a field feeds it the text and hands it the commands the keys send, and shows its list in a
// `CaretListWindow`. Only Return or a click picks; Tab picks nothing, which `perform` says and every host of the
// list calls first.

extension TypesStyle {
    /// The list's size: the `@` picker's.
    static let linkPickerMetrics = CaretListMetrics(width: 280, rowHeight: 24, rowsShown: 8, offset: 4)
    static let linkPickerAccessibilityLabel = "Notes"
    /// With nothing to list: `No Person notes`, `No notes` for a type with no title; with text and no match, Mentions' words.
    static func noNotes(of type: String?) -> String { type.map { "No \($0) notes" } ?? "No notes" }
    static let noMatches = "No matches"
}

@MainActor
public final class LinkPicker {
    private let editor: CanvasEditor
    private let owner: ShapeID
    public let type: ShapeID
    /// What's typed.
    public private(set) var query = ""
    /// What it lists for the query, row for row as the list shows them.
    public private(set) var choices: [MentionChoice] = []
    /// The list the picker shows: its rows as they're drawn and said, and the highlight.
    public let list = CaretList(metrics: TypesStyle.linkPickerMetrics)

    /// A picker listing the notes `owner` may point at under `type`, nothing typed yet: the recent picks and the notes
    /// nearest it, then those on other boards.
    public init(editor: CanvasEditor, owner: ShapeID, type: ShapeID) {
        self.editor = editor
        self.owner = owner
        self.type = type
        setQuery("")
    }

    /// Lists for `text` again (each keystroke), the first choice highlighted. The set of notes is made again each time
    /// (the type's notes, O(their number)), so a note given the type in the middle of a pick shows at the next keystroke.
    public func setQuery(_ text: String) {
        query = text
        guard let mentions = editor.mentions, let index = editor.types else {
            choices = []
            list.setRows([.empty(TypesStyle.noNotes(of: nil))])
            return
        }
        let targets = FieldLinks.targets(of: type, in: index)
        choices = mentions.choices(mentions.candidates(matching: text, in: AnyMentionable.self, for: owner, among: targets).all)
        if choices.isEmpty {
            let words = text.isEmpty ? TypesStyle.noNotes(of: typeName(index)) : TypesStyle.noMatches
            list.setRows([.empty(words)])
        } else {
            // A line is the name and the board's, as board 5 panel 3 draws it: no kind's symbol.
            list.setRows(MentionChoice.items(choices).map { item in
                var line = item
                line.symbol = nil
                line.tint = nil
                return .item(line)
            })
        }
    }

    private func typeName(_ index: TypeIndex) -> String? {
        if case .live(let title?) = index.name(of: TypeLink(type)) { title } else { nil }
    }

    /// Does what a command the keys send does to the list, as every caret list's keys do (`CaretList.perform`), but for
    /// these: Tab and ⇧Tab are never a pick (`.close`, not taken: the host closes the list and lets the key go on); Return
    /// picks the highlighted line, and with none is taken and does nothing, so what's typed is never stored and no
    /// newline goes in; Backspace on an empty query closes the list.
    public func perform(_ command: Selector) -> (taken: Bool, action: CaretList.Action?) {
        switch command {
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            return (false, .close)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertLineBreak(_:)):
            return list.highlightedItem == nil ? (true, nil) : (true, .pick)
        case #selector(NSResponder.deleteBackward(_:)):
            return query.isEmpty ? (true, .close) : (false, nil)
        default:
            return list.perform(command)
        }
    }

    /// The highlighted choice's value; nil with none. Tells Mentions it was picked, so it's first among the recent ones.
    public func pick() -> FieldLink? { list.highlighted.flatMap { pick(row: $0) } }

    /// The value of the choice at a row of the list (a click).
    public func pick(row: Int) -> FieldLink? {
        guard choices.indices.contains(row), let record = editor.shape(inFile: choices[row].candidate.id) else { return nil }
        editor.mentions?.didPick(record.id)
        return FieldLink.pointing(at: record, in: editor)
    }
}
