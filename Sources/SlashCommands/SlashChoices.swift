import AppKit
import FuzzyMatching
import TextEditing

/// One row a choice command lists (`SlashCommand`'s `choices:` form): what it is to the command
/// (`id`, opaque here), what it shows, and what the undo step is called if the pick says (a
/// command's rows may name different steps).
public struct SlashChoice: Equatable {
    public var id: String
    /// Matched against what's typed, and shown.
    public var title: String
    /// An SF Symbol before the title.
    public var symbol: String?
    public var detail: String?
    /// A line sets off a row whose group differs from the row above it.
    public var group: Int
    /// The undo step the pick makes; nil: the command's.
    public var step: String?
    /// With nothing typed, the first preferred row is highlighted; none: the first row.
    public var isPreferred: Bool
    /// The color of a capsule the row's symbol and title are drawn in (`CaretListItem.chip`); nil for a
    /// row drawn as every other is.
    public var chip: NSColor?

    public init(_ id: String, title: String, symbol: String? = nil, detail: String? = nil, group: Int = 0, step: String? = nil,
                isPreferred: Bool = false, chip: NSColor? = nil) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.detail = detail
        self.group = group
        self.step = step
        self.isPreferred = isPreferred
        self.chip = chip
    }
}

/// The list a text view shows after a choice command's name (`/is-a `), while it's open: what's
/// typed after the name (the query), the choices that lists, and which is highlighted. Headless, on
/// every caret list's model (`CaretList`), as `SlashCommandPicker` is: the text view feeds it the
/// text and the caret after each change (`read`). The command is asked for its rows once, when the
/// list opens; typing ranks those (`FuzzyMatcher`, best match first, then the command's order).
@MainActor
public final class SlashChoicePicker {
    /// Why an open picker closes, as the text read after a change says (`read`).
    public enum Closing: Hashable, Sendable {
        /// The caret left what's typed after the name: before it, past the line's end, or a selection.
        case caretLeft
        /// The `/` and the name aren't there as they were, or no whitespace follows the name.
        case nameChanged
    }

    let list = CaretList(metrics: SlashCommandStyle.choiceMetrics)
    /// What the rows are, in order: row for row with `rows`, none when `rows` is the one row that
    /// says nothing matches.
    public private(set) var listed: [SlashChoice] = []
    public private(set) var query = ""
    public let command: OfferedSlashCommand
    /// The `/` and the name it follows.
    public private(set) var nameRange: NSRange
    /// Where what's typed begins: after the space that follows the name.
    public let start: Int
    private let choices: [SlashChoice]

    init(offering command: OfferedSlashCommand, nameRange: NSRange, start: Int) {
        self.command = command
        self.nameRange = nameRange
        self.start = start
        choices = command.choices()
        setRows(for: "")
    }

    /// The index in `rows` of the highlighted row; nil when none can be picked.
    public var highlighted: Int? { list.highlighted }
    public var highlightedChoice: SlashChoice? { highlighted.map { listed[$0] } }
    public var rows: [CaretListRow] { list.rows }

    /// Reads the query again from the text and the selection after a change, and lists what it
    /// finds; or says why the picker closes.
    public func read(_ text: NSString, selection: NSRange, isEdit: Bool) -> Closing? {
        let name = "/" + command.name
        guard NSMaxRange(nameRange) < text.length, start <= text.length, NSMaxRange(nameRange) < start,
              text.substring(with: nameRange).lowercased() == name,
              SlashCommandLine.isWhitespace(text.character(at: NSMaxRange(nameRange))),
              !SlashCommandLine.isLineBreak(text.character(at: NSMaxRange(nameRange))) else { return .nameChanged }
        guard selection.length == 0 else { return .caretLeft }
        var lineStart = 0, lineEnd = 0, contentsEnd = 0
        text.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd, for: NSRange(location: start, length: 0))
        guard selection.location >= start, selection.location <= contentsEnd else { return .caretLeft }
        let typed = text.substring(with: NSRange(location: start, length: contentsEnd - start))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if typed != query { setRows(for: typed) }
        return nil
    }

    private func setRows(for query: String) {
        self.query = query
        var found: [(choice: SlashChoice, matched: [Range<Int>])]
        if query.isEmpty {
            found = choices.map { ($0, []) }
        } else {
            let matches = FuzzyMatcher.matches(query, in: choices.map(\.title))
            found = choices.indices.compactMap { index in matches[index].map { (index, $0) } }
                .sorted { a, b in a.1.score != b.1.score ? a.1.score > b.1.score : a.0 < b.0 }
                .map { (choices[$0.0], $0.1.matched) }
            if found.isEmpty, let other = command.choice(otherwise: query) { found = [(other, [])] }
        }
        listed = found.map(\.choice)
        var previous: Int?
        let rows: [CaretListRow] = found.isEmpty
            ? [.empty(query.isEmpty ? SlashCommandStyle.noChoices : SlashCommandStyle.noMatches)]
            : found.map { choice, matched in
                defer { previous = choice.group }
                return .item(CaretListItem(choice.title, matched: matched, symbol: choice.symbol, detail: choice.detail,
                                           separated: previous.map { $0 != choice.group } ?? false, chip: choice.chip))
            }
        list.setRows(rows)
        if query.isEmpty, let preferred = listed.firstIndex(where: \.isPreferred) { list.highlight(row: preferred) }
    }

    /// Highlights a row (the pointer's over it).
    public func highlight(row index: Int) { list.highlight(row: index) }

    /// Moves the highlight `steps` rows down (up, if negative): by one it wraps around the ends,
    /// by more (a page) it stops at them.
    public func moveHighlight(by steps: Int) { list.moveHighlight(by: steps) }
}
