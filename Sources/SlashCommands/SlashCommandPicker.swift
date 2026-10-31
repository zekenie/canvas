import AppKit
import Canvas
import FuzzyMatching
import TextEditing

/// A shape a command that takes one may be given, as the host found it by its name for what's typed after
/// a `/` (`SlashShapeSearch`): the list shows its label after the name of each command that admits it
/// ("move-near Groceries"), and a pick runs the command with it, as a pill on the command's line would.
public struct SlashShapeMatch: Equatable {
    public let id: ShapeID
    /// What the shape is called: shown, and the label the command is handed with it.
    public let label: String
    /// What's typed, in the label, as ranges of `Character` offsets (`FuzzyMatch.matched`).
    public let matched: [Range<Int>]
    /// Where the shape is, or its kind, at the row's trailing end.
    public let detail: String?
    /// Whether a detail too long for its room is cut at its start (a path, told by its last container).
    public let detailTruncatesHead: Bool
    /// The detail as VoiceOver says it ("in Alpha › Beta"); nil: as written.
    public let spoken: String?

    public init(_ id: ShapeID, label: String, matched: [Range<Int>] = [], detail: String? = nil, detailTruncatesHead: Bool = false,
                spoken: String? = nil) {
        self.id = id
        self.label = label
        self.matched = matched
        self.detail = detail
        self.detailTruncatesHead = detailTruncatesHead
        self.spoken = spoken
    }
}

/// How a host that names shapes finds them for what's typed after a `/`: the shapes called so, best first,
/// as its `@` picker would list them for that query on a plain line (Mentions'). Asked once a query, by name
/// alone: the list keeps the best few (`SlashCommandStyle.shapesListed`) and asks each command that takes a
/// shape whether it admits those, so a keystroke costs one search and a few of the commands' rules, however
/// many shapes the board or the target has and however many a rule would refuse.
public typealias SlashShapeSearch = @MainActor (_ query: String) -> [SlashShapeMatch]

/// The list a text view shows at a `/`, while it's open: what's typed after the slash (the query),
/// the commands that lists, and which is highlighted. It's the list's model, headless, built on
/// every caret list's (`CaretList`, TextEditing's, which keeps the highlight and says what the keys
/// do), as Mentions' `@` picker is: the text view feeds it the text and the caret after each change
/// (`read`) and shows its list in a `CaretListWindow`.
///
/// What's typed is matched against the commands' names and against what they take, so a person may
/// start from the thing and find what can be done with it: `/idea` lists `is-a Idea` (a choice of
/// `/is-a`'s list) and `move-near Idea` (a shape `/move-near` admits, as the host finds it), each a row
/// that runs as it's picked (`Entry.argument`). A command that takes words, which any query would
/// match, lists no argument.
///
/// When it opens and closes is its rules too, so a test can hold them without a view: a `/` typed
/// on an empty line opens it (`opens(in:at:)`); the caret leaving the query, the `/` deleted, a line
/// break or a mention's pill typed, what can't be in a name (whitespace, punctuation) where nothing
/// matches as an argument, a command's name and whitespace after it, and a query past
/// `SlashCommandStyle.queryLimit` characters close it (`Closing`).
@MainActor
public final class SlashCommandPicker {
    /// Why an open picker closes, as the text read after a change says (`read`).
    public enum Closing: Hashable, Sendable {
        /// The caret left the query: before the `/`, past what was typed, or a selection.
        case caretLeft
        /// The `/` isn't there any more.
        case slashDeleted
        /// What's typed holds a line break or a pill, or what can't be in a name (whitespace,
        /// punctuation) and nothing matches it as an argument, or it's a command's name done, with
        /// whitespace after it (its own list, if it has one, opens there).
        case nameEnded
        /// What's typed is longer than `SlashCommandStyle.queryLimit` characters.
        case tooLong
    }

    /// What a row gives its command, found by what's typed: a choice of its list, or a shape it admits.
    public enum Argument: Equatable {
        case choice(SlashChoice)
        case shape(SlashShapeMatch)
    }

    /// One row: a command (a pick completes its name), or a command with what it takes (a pick runs it).
    public struct Entry {
        public let command: OfferedSlashCommand
        /// Nil for the command alone.
        public let argument: Argument?
    }

    /// Where its `/` is: the character's index in the text.
    public let location: Int
    /// What's typed after the `/`, to the caret.
    public private(set) var query = ""
    /// What it lists for the query, row for row with `rows` (none when `rows` is the one row that
    /// says nothing matches).
    public private(set) var entries: [Entry] = []
    /// Each row's command.
    public var listed: [OfferedSlashCommand] { entries.map(\.command) }
    /// The `/` and what's typed there, past the caret too if it's in the middle of a name: what
    /// choosing a command replaces.
    public private(set) var nameRange: NSRange
    /// The index in `rows` of the highlighted row; nil when none can be picked.
    public var highlighted: Int? { list.highlighted }
    public var highlightedEntry: Entry? { highlighted.map { entries[$0] } }
    /// The highlighted row's command.
    public var highlightedCommand: OfferedSlashCommand? { highlightedEntry?.command }
    /// What it lists, as the window draws it.
    public var rows: [CaretListRow] { list.rows }
    /// The list the picker shows: its rows as they're drawn and said, and the highlight.
    let list = CaretList(metrics: SlashCommandStyle.metrics)
    /// How far the query reaches (a character index): typing moves it, so the caret can go back
    /// over the name and forward again, but not past it.
    private var queryEnd: Int
    private let offered: [OfferedSlashCommand]
    private let findShapes: SlashShapeSearch?
    /// Each choice command's rows (by its index in `offered`), asked once, when a query is first typed.
    private var choiceRows: [(command: Int, rows: [SlashChoice])]?

    /// A picker for the `/` at `location`, listing what a shape `offering` these commands, in this
    /// order, offers, and, with `findingShapes`, the shapes the commands that take one admit, as it finds
    /// them for what's typed.
    public init(at location: Int, offering commands: [OfferedSlashCommand], findingShapes: SlashShapeSearch? = nil) {
        self.location = location
        offered = commands
        findShapes = findingShapes
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
        guard !typed.utf16.contains(where: { SlashCommandLine.isLineBreak($0) || $0 == SlashCommandLine.pill }) else { return .nameEnded }
        guard typed.utf16.count <= SlashCommandStyle.queryLimit else { return .tooLong }
        let isName = typed.utf16.allSatisfy(SlashCommandLine.isNameCharacter)
        if !isName, isCommandDone(typed) { return .nameEnded }
        var nameEnd = caret
        while nameEnd < text.length, SlashCommandLine.isNameCharacter(text.character(at: nameEnd)) { nameEnd += 1 }
        nameRange = NSRange(location: location, length: nameEnd - location)
        if typed != query { setRows(for: typed) }
        if !isName, entries.isEmpty { return .nameEnded }
        return nil
    }

    /// Whether what's typed is a command's name and whitespace after it: the line is that command's now.
    private func isCommandDone(_ typed: String) -> Bool {
        guard let space = typed.firstIndex(where: \.isWhitespace) else { return false }
        let name = typed[..<space].lowercased()
        return offered.contains { $0.name == name }
    }

    // MARK: Rows

    /// Lists what the query finds, the first row highlighted: every command in the order it was
    /// offered for an empty query; else the names it matches and what the commands take that it
    /// matches (the choices of those that take one; for those that take a shape, the best few shapes the
    /// host finds by name, `SlashCommandStyle.shapesListed`, each with every command that admits it), best
    /// tier first (`FuzzyRanking`), a name before an argument and a choice before a shape, the choices in
    /// the order offered and then their own, the shapes in the host's order, each with its commands in the
    /// order offered; or the one row that says nothing matches. A query that can't be a name (whitespace,
    /// punctuation) matches arguments alone.
    private func setRows(for query: String) {
        self.query = query
        var found: [(entry: Entry, matched: [Range<Int>], score: Int, order: [Int])] = []
        let words = query.trimmingCharacters(in: .whitespaces)
        if query.isEmpty {
            found = offered.enumerated().map { (Entry(command: $1, argument: nil), [], 0, [$0]) }
        } else {
            if query.utf16.allSatisfy(SlashCommandLine.isNameCharacter) {
                for (index, match) in FuzzyMatcher.matches(query, in: offered.map(\.name)).enumerated() {
                    guard let match else { continue }
                    found.append((Entry(command: offered[index], argument: nil), match.matched, match.score, [0, index]))
                }
            }
            found += arguments(matching: words)
        }
        found.sort { a, b in
            a.score != b.score ? a.score > b.score : a.order.lexicographicallyPrecedes(b.order)
        }
        entries = found.map(\.entry)
        let rows: [CaretListRow] = found.isEmpty ? [.empty(SlashCommandStyle.noMatches)] : found.map { entry, matched, _, _ in
            .item(SlashCommandStyle.item(entry, matched: matched))
        }
        list.setRows(rows)
    }

    /// What the commands take that `words` matches, each with its match, its tier and its order: after
    /// every name (`[1, …]`), the choices by command and then their place (`[1, 0, command, place]`), then
    /// the shapes one at a time (`[1, 1, place, command]`), so a shape's rows are together: `move-near Idea`,
    /// `send-behind Idea`.
    private func arguments(matching words: String) -> [(entry: Entry, matched: [Range<Int>], score: Int, order: [Int])] {
        guard !words.isEmpty else { return [] }
        if choiceRows == nil {
            choiceRows = offered.indices.filter { offered[$0].takesChoice }.map { ($0, offered[$0].choices()) }
        }
        var found: [(entry: Entry, matched: [Range<Int>], score: Int, order: [Int])] = []
        for (index, rows) in choiceRows ?? [] {
            for (position, match) in FuzzyMatcher.matches(words, in: rows.map(\.title)).enumerated() {
                guard let match else { continue }
                found.append((Entry(command: offered[index], argument: .choice(rows[position])), match.matched, match.score,
                              [1, 0, index, position]))
            }
        }
        let takers = offered.indices.filter { offered[$0].takesShape }
        guard let findShapes, !takers.isEmpty else { return found }
        for (position, shape) in findShapes(words).prefix(SlashCommandStyle.shapesListed).enumerated() {
            // Ranked as a choice is by its label; one the host found by its path or a typo ranks below every tier.
            let score = FuzzyMatcher.match(words, in: shape.label)?.score ?? 0
            for index in takers where offered[index].admits(shape.id) {
                found.append((Entry(command: offered[index], argument: .shape(shape)), shape.matched, score, [1, 1, position, index]))
            }
        }
        return found
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
    /// The longest query that's typed to list by, in characters: a title's longest (Titles'), what an
    /// argument may be called.
    static let queryLimit = 80
    /// How many of the shapes the host finds by name for a query the commands that take one are asked about.
    static let shapesListed = 4

    /// A row: the name and its hint; or, for a command with what it takes, the line it stands for
    /// ("is-a Idea", what's typed matched in the argument) and what the argument says (a type's
    /// count, where a shape is).
    static func item(_ entry: SlashCommandPicker.Entry, matched: [Range<Int>]) -> CaretListItem {
        let command = entry.command
        guard let argument = entry.argument else {
            return CaretListItem(command.name, matched: matched, detail: detail(of: command), spoken: spoken(of: command))
        }
        let shift = command.name.count + 1
        let reach = command.isPartial ? self.reach(command.shapes.count, of: command.targetCount) : nil
        let spokenReach = command.isPartial ? self.spokenReach(command.shapes.count, of: command.targetCount) : nil
        let title: String, detail: String?, said: String?, truncatesHead: Bool
        switch argument {
        case .choice(let choice):
            // A choice that counts the shapes it's for ("2 of 3") says their reach already.
            title = choice.title
            detail = choice.detail ?? reach
            said = choice.detail ?? spokenReach
            truncatesHead = false
        case .shape(let shape):
            title = shape.label
            let shown = [shape.detail, reach].compactMap { $0 }, spoken = [shape.spoken ?? shape.detail, spokenReach].compactMap { $0 }
            detail = shown.isEmpty ? nil : shown.joined(separator: " · ")
            said = spoken.isEmpty ? nil : spoken.joined(separator: ", ")
            truncatesHead = shape.detailTruncatesHead
        }
        let line = "\(command.name) \(title)"
        return CaretListItem(line, matched: matched.map { ($0.lowerBound + shift)..<($0.upperBound + shift) }, detail: detail,
                             detailTruncatesHead: truncatesHead, spoken: said.map { "\(line), \($0)" } ?? line)
    }

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
