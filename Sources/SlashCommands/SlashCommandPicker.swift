import AppKit
import FuzzyMatching
import TextEditing

/// The list a text view shows at a `/`, while it's open: what's typed after the slash (the query),
/// the commands that lists, and which is highlighted. It's the list's model, headless, built on
/// every caret list's (`CaretList`, TextEditing's, which keeps the highlight and says what the keys
/// do), as Mentions' `@` picker is: the text view feeds it the text and the caret after each change
/// (`read`) and shows its list in a `CaretListWindow`.
///
/// When it opens and closes is its rules too, so a test can hold them without a view: a `/` typed
/// on an empty line opens it (`opens(in:at:)`); the caret leaving the name, the `/` deleted,
/// anything in the name that can't be in one (whitespace ends it, so does a line break, a mention's
/// pill, punctuation) and a name past `SlashCommandStyle.nameLimit` characters close it (`Closing`).
@MainActor
public final class SlashCommandPicker {
    /// Why an open picker closes, as the text read after a change says (`read`).
    public enum Closing: Hashable, Sendable {
        /// The caret left the name: before the `/`, past what was typed, or a selection.
        case caretLeft
        /// The `/` isn't there any more.
        case slashDeleted
        /// What's typed holds what can't be in a name: whitespace, a line break, a pill, punctuation.
        case nameEnded
        /// The name is longer than `SlashCommandStyle.nameLimit` characters.
        case tooLong
    }

    /// Where its `/` is: the character's index in the text.
    public let location: Int
    /// What's typed after the `/`, to the caret.
    public private(set) var query = ""
    /// The commands it lists for the query, row for row with `rows` (none when `rows` is the one
    /// row that says nothing matches).
    public private(set) var listed: [OfferedSlashCommand] = []
    /// The `/` and the name there, past the caret too if it's in the middle of one: what choosing a
    /// command replaces.
    public private(set) var nameRange: NSRange
    /// The index in `rows` of the highlighted row; nil when none can be picked.
    public var highlighted: Int? { list.highlighted }
    /// The highlighted row's command.
    public var highlightedCommand: OfferedSlashCommand? { highlighted.map { listed[$0] } }
    /// What it lists, as the window draws it.
    public var rows: [CaretListRow] { list.rows }
    /// The list the picker shows: its rows as they're drawn and said, and the highlight.
    let list = CaretList(metrics: SlashCommandStyle.metrics)
    /// How far the query reaches (a character index): typing moves it, so the caret can go back
    /// over the name and forward again, but not past it.
    private var queryEnd: Int
    private let offered: [OfferedSlashCommand]

    /// A picker for the `/` at `location`, listing what a shape `offering` these commands, in this
    /// order, offers.
    public init(at location: Int, offering commands: [OfferedSlashCommand]) {
        self.location = location
        offered = commands
        queryEnd = location + 1
        nameRange = NSRange(location: location, length: 1)
        setRows(for: "")
    }

    // MARK: Opening and closing

    /// Whether a `/` at `location` of `text` opens the list: on an empty line, at the start of the
    /// text or right after a line break, with nothing after it on its line. Not at the start of a
    /// line that has text (the line is evaluated whole, so a command chosen there would take that
    /// text with it), and never in the middle of one.
    public static func opens(in text: NSString, at location: Int) -> Bool {
        guard location >= 0, location < text.length, text.character(at: location) == SlashCommandLine.slash else { return false }
        var start = 0, end = 0, contentsEnd = 0
        text.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: location, length: 0))
        return start == location && contentsEnd == location + 1
    }

    /// Reads the query again from the text and the selection after a change, and lists what it
    /// finds; or says why the picker closes. `isEdit` is whether the text changed (typing moves the
    /// query's end to the caret), rather than only the selection.
    public func read(_ text: NSString, selection: NSRange, isEdit: Bool) -> Closing? {
        guard location < text.length, text.character(at: location) == SlashCommandLine.slash else { return .slashDeleted }
        guard selection.length == 0 else { return .caretLeft }
        let caret = selection.location
        guard caret > location, caret <= text.length else { return .caretLeft }
        if isEdit {
            queryEnd = caret
        } else if caret > queryEnd {
            return .caretLeft
        }
        let typed = text.substring(with: NSRange(location: location + 1, length: caret - location - 1))
        guard typed.utf16.allSatisfy(SlashCommandLine.isNameCharacter) else { return .nameEnded }
        guard typed.utf16.count <= SlashCommandStyle.nameLimit else { return .tooLong }
        var nameEnd = caret
        while nameEnd < text.length, SlashCommandLine.isNameCharacter(text.character(at: nameEnd)) { nameEnd += 1 }
        nameRange = NSRange(location: location, length: nameEnd - location)
        if typed != query { setRows(for: typed) }
        return nil
    }

    // MARK: Rows

    /// Lists what the query finds, the first command highlighted: every command in the order it was
    /// offered for an empty query; else those whose names it matches, best tier first
    /// (`FuzzyRanking`), then in the order offered; or the one row that says nothing matches.
    private func setRows(for query: String) {
        self.query = query
        let found: [(command: OfferedSlashCommand, matched: [Range<Int>])]
        if query.isEmpty {
            found = offered.map { ($0, []) }
        } else {
            let matches = FuzzyMatcher.matches(query, in: offered.map(\.name))
            found = offered.indices.compactMap { index in matches[index].map { (index, $0) } }
                .sorted { a, b in a.1.score != b.1.score ? a.1.score > b.1.score : a.0 < b.0 }
                .map { (offered[$0.0], $0.1.matched) }
        }
        listed = found.map(\.command)
        let rows: [CaretListRow] = found.isEmpty ? [.empty(SlashCommandStyle.noMatches)] : found.map { command, matched in
            .item(CaretListItem(command.name, matched: matched, detail: SlashCommandStyle.detail(of: command),
                                spoken: SlashCommandStyle.spoken(of: command)))
        }
        list.setRows(rows)
    }

    /// Highlights a row (the pointer's over it); the one that says nothing matches highlights nothing.
    public func highlight(row index: Int) { list.highlight(row: index) }

    /// Moves the highlight `steps` commands down (up, if negative): by one it wraps around the ends,
    /// by more (a page) it stops at them.
    public func moveHighlight(by steps: Int) { list.moveHighlight(by: steps) }
}

/// The list's size and words: its own; its look is every caret list's.
@MainActor
enum SlashCommandStyle {
    static let listWidth: CGFloat = 240
    static let rowHeight: CGFloat = 24
    static let rowsShown = 8
    /// Below the line the `/` is on.
    static let offset: CGFloat = 4
    static let metrics = CaretListMetrics(width: listWidth, rowHeight: rowHeight, rowsShown: rowsShown, offset: offset)
    static let noMatches = "No matches"
    /// A choice command's list: taller rows (chips), and what an empty one says.
    static let choiceMetrics = CaretListMetrics(width: listWidth, rowHeight: 28, rowsShown: rowsShown, offset: offset)
    static let noChoices = "None"
    static let choicesAccessibilityLabel = "Choices"
    /// What VoiceOver calls the list.
    static let accessibilityLabel = "Commands"
    /// The longest name that's typed to list by, in characters.
    static let nameLimit = 40

    // MARK: How many shapes a row acts on

    /// How many of the target's shapes a command acts on, where that's fewer than all: "4 of 5".
    static func reach(_ count: Int, of total: Int) -> String { "\(count) of \(total)" }

    /// The same, said: "acts on 4 of 5 shapes".
    static func spokenReach(_ count: Int, of total: Int) -> String { "acts on \(count) of \(total) shapes" }

    /// What a row says after the name: the hint, and how many it acts on where that's fewer than the
    /// target's shapes ("type · 4 of 5"). A text's line is never partial, so a note's rows are its hints.
    static func detail(of command: OfferedSlashCommand) -> String? {
        guard command.isPartial else { return command.argument }
        let reach = reach(command.shapes.count, of: command.targetCount)
        return command.argument.map { "\($0) · \(reach)" } ?? reach
    }

    /// What VoiceOver says of a row: "is-a, takes type, acts on 4 of 5 shapes".
    static func spoken(of command: OfferedSlashCommand) -> String {
        let said = command.argument.map { "\(command.name), takes \($0)" } ?? command.name
        guard command.isPartial else { return said }
        return said + ", " + spokenReach(command.shapes.count, of: command.targetCount)
    }

    // MARK: The command as typed (`SlashCommandTyping`'s highlights)

    /// A command typed on a line is marked as a mention's pill is, behind the text and in the text's
    /// own color so it follows whatever surface the text is on (a pill's is 10%): the `/name` firmly,
    /// and what the command is given in a lighter shade of it.
    static let commandFill: CGFloat = 0.18
    static let argumentsFill: CGFloat = 0.08
}
