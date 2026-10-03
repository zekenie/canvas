import AppKit
import TextEditing

// A code editor's completions (`DetailCodeEditor`'s `completions:`): a plugin says what can be
// typed at the caret, in its language, and the editor lists it there, in the app's one caret list
// (`CaretList`, as Mentions' `@` picker is), ranked by what's typed with the one matcher
// (`CaretListMatcher`), and puts a pick in. The language is the plugin's; the keys, the list and
// the ranking are the panel's.

/// What can be typed at a code editor's caret: asked with the text and the caret (UTF-16, as
/// `NSString` counts), nil where nothing can. It's asked as the list opens and after every
/// keystroke and move of the caret while it's open, so keep it to what the caret's place costs,
/// not the text's length.
public typealias DetailCodeCompleting = @MainActor (_ text: String, _ caret: Int) -> DetailCodeCompletions?

/// What a code editor's provider offers at a caret: every candidate, in the order it offers them,
/// unfiltered (the list matches them against what's typed itself).
public struct DetailCodeCompletions: Equatable, Sendable {
    /// What a pick replaces with its item's `insert`, as `NSString` counts (UTF-16). It holds the
    /// caret, or nothing is listed.
    public var range: NSRange
    /// What's typed so far, which the list matches the items' labels against: nothing typed, it
    /// lists every item as offered.
    public var query: String
    public var items: [DetailCodeCompletion]

    public init(range: NSRange, query: String, items: [DetailCodeCompletion]) {
        self.range = range
        self.query = query
        self.items = items
    }
}

/// One candidate: what its row says, and what a pick puts in the text.
public struct DetailCodeCompletion: Equatable, Sendable {
    /// What its row shows, and what's typed is matched against.
    public var label: String
    /// A line about it, after the label in its row; "" for none.
    public var detail: String
    /// What replaces the completions' `range` once it's picked.
    public var insert: String
    /// Within `insert` (UTF-16): where the caret goes once it's in (an empty range), or what's
    /// selected, to be typed over.
    public var selection: NSRange
    /// Where the pick leaves the caret has completions of its own: the list asks again there at
    /// once, and opens if anything's offered.
    public var reopens: Bool
    /// Whether it matters where it's offered: of the items what's typed matches alike, those that
    /// do come first.
    public var isRelevant: Bool

    /// `selection` nil: the caret after `insert`.
    public init(label: String, detail: String = "", insert: String, selection: NSRange? = nil, reopens: Bool = false, isRelevant: Bool = true) {
        self.label = label
        self.detail = detail
        self.insert = insert
        self.selection = selection ?? NSRange(location: (insert as NSString).length, length: 0)
        self.reopens = reopens
        self.isRelevant = isRelevant
    }
}

extension DetailCodeCompletions {
    /// An item as the list shows it: with its label's characters what's typed matched.
    struct Listed {
        let item: DetailCodeCompletion
        let matched: [Range<Int>]
    }

    /// What the list shows, in order: every item as offered while nothing's typed; else the items
    /// what's typed matches, the best tier first (`CaretListRanking`), then those that matter, then
    /// as offered. Nothing, where nothing matches.
    func listed() -> [Listed] {
        guard !CaretListMatcher.Query(query).isEmpty else { return items.map { Listed(item: $0, matched: []) } }
        let matches = CaretListMatcher.matches(query, in: items.map(\.label))
        let found = items.indices.compactMap { i in matches[i].map { (index: i, match: $0) } }
        return found.sorted { a, b in
            if a.match.score != b.match.score { return a.match.score > b.match.score }
            if items[a.index].isRelevant != items[b.index].isRelevant { return items[a.index].isRelevant }
            return a.index < b.index
        }
        .map { Listed(item: items[$0.index], matched: $0.match.matched) }
    }
}

extension DetailStyle {
    // MARK: A code editor's completions

    /// Its size: room for a line of description after a long keyword (JSON Schema's longest,
    /// `additionalProperties`, and its 46 characters: the detail takes what the label leaves); a
    /// row a line of code. Its look is every caret list's.
    static let completionsWidth: CGFloat = 410
    static let completionsRowHeight: CGFloat = 20
    static let completionsRowsShown = 10
    /// Below the line the caret's on.
    static let completionsOffset: CGFloat = 3
    static let completionsMetrics = CaretListMetrics(width: completionsWidth, rowHeight: completionsRowHeight,
                                                     rowsShown: completionsRowsShown, offset: completionsOffset)
    /// What VoiceOver calls the list.
    static let completionsAccessibilityLabel = "Completions"
}
