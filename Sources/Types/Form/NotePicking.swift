import AppKit
import Canvas
import TextEditing

// The list a row's or a cell's field finds a note in while it is typed in: what every host of the list (a row's
// field, the form's cell editor) asks of whatever lists the notes, and the rule of its keys, which is the same
// for every list. Only Return or a click picks; Tab picks nothing, which `perform` says and every host of the
// list calls first.

/// What lists notes for a field to find one in: the text typed so far, the list as it is drawn and said, and the
/// note a line stands for. Headless, as `ReferencePicker` is: a field feeds it the text and hands it the commands
/// the keys send, and shows its list in a `CaretListWindow`.
@MainActor
public protocol NotePicking: AnyObject {
    /// What's typed.
    var query: String { get }
    /// The list the picker shows: its rows as they're drawn and said, and the highlight.
    var list: CaretList { get }
    /// Lists for `text` again (each keystroke), the first line highlighted.
    func setQuery(_ text: String)
    /// The note the line at a row of the list stands for (a click, or Return on the highlighted line); nil for a row
    /// that is no line. Tells Mentions it was picked, so it is first among the recent ones.
    func pickNote(row: Int) -> ShapeID?
}

extension NotePicking {
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
}

extension TypesStyle {
    /// The list's size: the `@` picker's.
    static let relationPickerMetrics = CaretListMetrics(width: 280, rowHeight: 24, rowsShown: 8, offset: 4)
    static let relationPickerAccessibilityLabel = "Notes"
    /// With nothing to list: `No Person notes`, `No notes` for a type with no title; with text and no match, Mentions' words.
    static func noNotes(of type: String?) -> String { type.map { "No \($0) notes" } ?? "No notes" }
    static let noMatches = "No matches"
}
