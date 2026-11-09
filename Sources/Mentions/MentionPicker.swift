import AppKit
import Canvas
import TextEditing

/// One row of the `@` picker: a section's header, a shape that can be picked, the one row an
/// empty list shows instead (quiet: "No matches", "Nothing to mention"), or, for a host that takes
/// words as well as shapes, the words typed (`wordsRow`). A shape's row and the words' can be
/// highlighted and picked.
public enum MentionPickerRow: Hashable, Sendable {
    case header(String)
    case candidate(MentionCandidate)
    case empty(String)
    /// What's typed after the `@`, last, for a host that takes words: picked, they're its whole.
    case words(String)

    /// The shape a row picks; nil for a header or an empty state.
    public var candidate: MentionCandidate? {
        if case .candidate(let candidate) = self { candidate } else { nil }
    }
}

/// The `@` picker of a mention text view, while it's open: what's typed after its `@` (the query),
/// the rows that lists, and which row is highlighted. It's the picker's model, headless, built on
/// every caret list's (`CaretList`, DetailPanel's, which keeps the highlight and says what the keys
/// do): the text view feeds it the text and the caret after each change (`read`), hands it the
/// commands the keys send (`perform`), and shows its list in a `CaretListWindow`. It lists what the
/// text's scope admits, and on the line of a slash command that takes one shape (`kinds`,
/// `admitting`) only what the command admits too.
///
/// When it opens and closes is its rules too, so a test can hold them without a view: an `@` typed
/// at the start of the text, after whitespace or a line break, or after an opening bracket or
/// quote opens it (`opens(in:at:)`); the caret leaving the query, the `@` deleted, a line break in
/// the query, a query longer than `MentionStyle.queryLimit` characters, and a query ending in a
/// space that matches nothing close it (`Closing`). A picker that takes words (`wordsRow`) ends a
/// typed query's list with the words themselves, set off from the shapes above them, the highlight
/// on them once no shape is left; it never says "No matches", and a space never closes it.
@MainActor
public final class MentionPicker {
    /// Why an open picker closes, as the text read after a change says (`read`).
    public enum Closing: Hashable, Sendable {
        /// The caret left the query: before the `@`, past what was typed, or a selection.
        case caretLeft
        /// The `@` isn't there any more.
        case atDeleted
        /// The query holds a line break.
        case newline
        /// The query is longer than `MentionStyle.queryLimit` characters (a title's longest).
        case tooLong
        /// The query ends in a space and nothing matches: the person was just writing.
        case spaceWithoutMatch
    }

    /// What a command the keys send does while the picker is open: its list's (`CaretList.Action`).
    public enum Action: Hashable, Sendable {
        case moveUp, moveDown, pageUp, pageDown, pick, close, closeAndPass

        init(_ action: CaretList.Action) {
            switch action {
            case .moveUp: self = .moveUp
            case .moveDown: self = .moveDown
            case .pageUp: self = .pageUp
            case .pageDown: self = .pageDown
            case .pick: self = .pick
            case .close: self = .close
            case .closeAndPass: self = .closeAndPass
            }
        }
    }

    /// Where its `@` is: the character's index in the text.
    public let location: Int
    /// What's typed after the `@`, to the caret.
    public private(set) var query = ""
    /// What it lists for the query: its list's rows, index for index, each with its shape.
    public private(set) var rows: [MentionPickerRow] = []
    /// The index in `rows` of the highlighted row, always a shape's; nil when none can be picked.
    public var highlighted: Int? { list.highlighted }
    /// The list the picker shows: its rows as they're drawn and said, and the highlight.
    public let list = CaretList(metrics: MentionStyle.pickerMetrics)
    /// How far the query reaches (a character index): typing moves it, so the caret can go back
    /// over the query and forward again, but not past it.
    private var queryEnd: Int
    /// What the picker lists for a query.
    private let search: @MainActor (String) -> MentionCandidates
    /// Whether a typed query's list ends with its words (`MentionPickerRow.words`).
    public let wordsRow: Bool
    /// Called after the rows or the highlight change.
    var onChange: (@MainActor () -> Void)?

    /// A picker for the `@` at `location`, listing what `search` finds for each query, and, with
    /// `wordsRow`, the words typed after the shapes.
    public init(at location: Int, wordsRow: Bool = false, search: @escaping @MainActor (String) -> MentionCandidates) {
        self.location = location
        self.search = search
        self.wordsRow = wordsRow
        queryEnd = location + 1
        setRows(for: "")
        list.onChange = { [weak self] in self?.onChange?() }
    }

    /// A picker listing what `mentions` offers text of `scope` for `owners` (the text's shape, which may
    /// mention itself, or the shapes the command bar types for: nearness is measured from the middle of
    /// them, and each is left out of Nearby), and of that only the shapes of `kinds` and what
    /// `admitting` admits, if there are any: the shapes a slash command on the line takes
    /// (`SlashCommandTyping.admittedShapes(at:)`), asked wherever a shape is listed. With kinds only
    /// their shapes are ranked (`MentionState.candidates`).
    public convenience init<S: MentionScope>(at location: Int, mentions: MentionState, scope: S.Type, owners: [ShapeID],
                                             kinds: Set<ShapeKind>? = nil,
                                             admitting admits: (@MainActor (ShapeID) -> Bool)? = nil, listingRows: Bool = false,
                                             wordsRow: Bool = false) {
        // With `listingRows`, the rows of the shapes listed too (a column under its table's name, an endpoint by its own): a pick
        // mentions the row.
        self.init(at: location, wordsRow: wordsRow) { [weak mentions] query in
            guard let mentions else { return MentionCandidates() }
            if listingRows { return mentions.candidates(matching: query, in: scope, for: owners, kinds: kinds, admitting: admits, listingParts: { _ in true }, ownRows: .shape) }
            return mentions.candidates(matching: query, in: scope, for: owners, kinds: kinds, admitting: admits)
        }
    }

    /// `init(at:mentions:scope:owners:kinds:admitting:)` for text on `owner`, or on no shape.
    public convenience init<S: MentionScope>(at location: Int, mentions: MentionState, scope: S.Type, owner: ShapeID?,
                                             kinds: Set<ShapeKind>? = nil,
                                             admitting admits: (@MainActor (ShapeID) -> Bool)? = nil, wordsRow: Bool = false) {
        self.init(at: location, mentions: mentions, scope: scope, owners: owner.map { [$0] } ?? [], kinds: kinds, admitting: admits,
                  wordsRow: wordsRow)
    }

    // MARK: Opening and closing

    /// Whether an `@` typed at `location` of `text` opens the picker: at the start of the text,
    /// after whitespace or a line break, or after `(`, `[`, `{`, `"`, `'`, `“` or `‘`; never in a
    /// word (`name@example.com`).
    public static func opens(in text: NSString, at location: Int) -> Bool {
        guard location >= 0, location < text.length, text.character(at: location) == 0x40 else { return false }
        guard location > 0 else { return true }
        let before = text.character(at: location - 1)
        if let scalar = Unicode.Scalar(before), scalar.properties.isWhitespace { return true }
        return opensAfter.contains(before)
    }

    /// What an `@` may follow, besides whitespace, to open the picker.
    private static let opensAfter: Set<unichar> = Set("([{\"'“‘".utf16)

    /// Reads the query again from the text and the selection after a change, and lists what it
    /// finds; or says why the picker closes. `isEdit` is whether the text changed (typing moves the
    /// query's end to the caret), rather than only the selection.
    public func read(_ text: NSString, selection: NSRange, isEdit: Bool) -> Closing? {
        guard location < text.length, text.character(at: location) == 0x40 else { return .atDeleted }
        guard selection.length == 0 else { return .caretLeft }
        let caret = selection.location
        guard caret > location, caret <= text.length else { return .caretLeft }
        if isEdit {
            queryEnd = caret
        } else if caret > queryEnd {
            return .caretLeft
        }
        let typed = text.substring(with: NSRange(location: location + 1, length: caret - location - 1))
        if typed.contains(where: \.isNewline) { return .newline }
        if typed.unicodeScalars.contains("\u{FFFC}") { return .caretLeft }
        if typed.count > MentionStyle.queryLimit { return .tooLong }
        if typed != query { setRows(for: typed) }
        if typed.last?.isWhitespace == true, highlighted == nil { return .spaceWithoutMatch }
        return nil
    }

    // MARK: Rows

    /// Lists what the query finds, the first shape highlighted: for an empty query, the recent picks
    /// and the shapes nearby, each under its header; for any other, the best matches, and then, for a
    /// picker that takes words, the words (highlighted where no shape is listed).
    private func setRows(for query: String) {
        self.query = query
        let found = search(query)
        var rows: [MentionPickerRow] = []
        if query.isEmpty {
            if !found.recent.isEmpty { rows += [.header(MentionStyle.recentHeader)] + found.recent.map { .candidate($0) } }
            if !found.nearby.isEmpty { rows += [.header(MentionStyle.nearbyHeader)] + found.nearby.map { .candidate($0) } }
            if rows.isEmpty { rows = [.empty(MentionStyle.nothingToMention)] }
        } else {
            rows = found.matches.map { .candidate($0) }
            if wordsRow, query.contains(where: { !$0.isWhitespace }) {
                rows.append(.words(query))
            } else if rows.isEmpty {
                rows = [.empty(MentionStyle.noMatches)]
            }
        }
        self.rows = rows
        list.setRows(Self.listRows(rows))
    }

    /// The rows as the list draws and says them: a shape's symbol in its tint, its label with the
    /// matched characters, a lock after a read-only shape's, and its detail at the trailing end: where
    /// the shape is, if it is in a container ("Alpha › Beta"), else its kind's; said as
    /// "Groceries, Note, 2 of 7", or "Checkout, Note, in Alpha › Beta, 2 of 7".
    private static func listRows(_ rows: [MentionPickerRow]) -> [CaretListRow] {
        let shapes = rows.lazy.filter { $0.candidate != nil }.count
        var position = 0
        return rows.map { row in
            switch row {
            case .header(let words): return .header(words)
            case .empty(let words): return .empty(words)
            case .words(let words): return .item(wordsItem(words, separated: shapes > 0))
            case .candidate(let candidate):
                position += 1
                let appearance = candidate.appearance
                let place = candidate.place
                return .item(CaretListItem(appearance.label, matched: candidate.matched, symbol: appearance.systemImage, tint: appearance.tint,
                                           detail: place?.text ?? appearance.detail, detailMatched: place?.matched ?? [], detailDimmed: place?.dimmed ?? [],
                                           detailTruncatesHead: place != nil, place: place?.caretPlace(),
                                           trailingSymbol: candidate.isReadOnly ? MentionStyle.readOnlySymbol : nil,
                                           spoken: "\(appearance.label), \(appearance.kindName)\(place.map { ", " + $0.spoken } ?? ""), \(position) of \(shapes)"))
            }
        }
    }

    /// The highlighted row's shape.
    public var highlightedCandidate: MentionCandidate? { highlighted.flatMap { rows[$0].candidate } }

    /// The words, when their row is the one highlighted.
    public var highlightedWords: String? {
        guard let highlighted, case .words(let words) = rows[highlighted] else { return nil }
        return words
    }

    /// Whether the words are all that's left: no shape matches what's typed.
    public var isHandoff: Bool {
        guard rows.count == 1, case .words = rows[0] else { return false }
        return true
    }

    /// The words' row as every list that takes words draws and says it (this picker's, a reference's):
    /// a magnifier and the words as typed, a line above it when shapes are listed (`separated`), said
    /// "Words, …".
    public static func wordsItem(_ words: String, separated: Bool) -> CaretListItem {
        CaretListItem(words, symbol: MentionStyle.wordsSymbol, separated: separated, spoken: "\(MentionStyle.wordsSpoken), \(words)")
    }

    /// Highlights a row (the pointer's over it); a header or an empty state highlights nothing new.
    public func highlight(row index: Int) { list.highlight(row: index) }

    /// Moves the highlight `steps` shapes down (up, if negative): by one it wraps around the ends,
    /// by more (a page) it stops at them.
    public func moveHighlight(by steps: Int) { list.moveHighlight(by: steps) }

    // MARK: Keys

    /// What a text view command does while the picker is open, if it takes it: every caret list's
    /// keys. ↑/↓ (and ⌃P/⌃N) move the highlight, Page Up/Down (and ⌥) by a page, Return and Tab
    /// pick, Escape and ⌥⎋ close. Every other command (←/→ among them) is the text view's.
    public static func action(for command: Selector) -> Action? {
        CaretList.action(for: command).map(Action.init)
    }

    /// Does what a command does to the list: whether the picker takes it (the text view then
    /// doesn't run it), and what's left for the view to carry out, `.pick` or `.close` (nil when
    /// moving the highlight was all). Return with nothing to pick isn't taken, so it does what it would
    /// without the picker; Tab with nothing to pick and ⇧Tab always are, as `.closeAndPass`: the list
    /// closes and the view then carries the key out. Nor is any command the picker doesn't know.
    public func perform(_ command: Selector) -> (taken: Bool, action: Action?) {
        let (taken, action) = list.perform(command)
        return (taken, action.map(Action.init))
    }

    // MARK: Picking

    /// Whether a pick puts a space after its pill, given the character after the query (nil at the
    /// end of the text, where it does): not before whitespace or `. , ; : ! ? ) ] } ” ’ ' "`.
    public static func spaceAfterPick(before next: unichar?) -> Bool {
        guard let next else { return true }
        if let scalar = Unicode.Scalar(next), scalar.properties.isWhitespace { return false }
        return !noSpaceBefore.contains(next)
    }

    private static let noSpaceBefore: Set<unichar> = Set(".,;:!?)]}”’'\"".utf16)
}

extension MentionStyle {
    /// The picker's sections and empty states: quiet, one row each.
    static let recentHeader = "Recent"
    static let nearbyHeader = "Nearby"
    static let noMatches = "No matches"
    static let nothingToMention = "Nothing to mention"
    /// After a read-only shape's label.
    static let readOnlySymbol = "lock.fill"
    /// The words' row: its symbol, and what VoiceOver says before the words.
    static let wordsSymbol = "magnifyingglass"
    static let wordsSpoken = "Words"
    /// What VoiceOver calls the picker's list.
    static let pickerAccessibilityLabel = "Mentions"
    /// The picker's size, its own; its look is every caret list's.
    static let pickerMetrics = CaretListMetrics(width: pickerWidth, rowHeight: pickerRowHeight, rowsShown: pickerRowsShown,
                                                offset: pickerOffset)
}
