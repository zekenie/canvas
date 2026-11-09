import AppKit

// What can be typed at a caret, in a language a host knows: the panel's code editor's completions (DetailPanel's
// `DetailCodeCompletions`, a name for these) and a row written as a line (LineRows'). The host says what's offered, the
// one caret list shows it (`CaretList`), ranked by what's typed with the one matcher, which the host passes in
// (`listed(scoring:)`: FuzzyMatching's, which TextEditing stays free of), and a pick puts an item's text in. An item may
// instead be an action ("New type Problem"), which a list that picks only actions on Return does (`CaretList.returnPicks`).

/// What's offered at a caret: every candidate, in the order offered, unfiltered (the list matches them against what's
/// typed itself).
public struct CaretCompletions: Equatable, Sendable {
    /// What a pick replaces with its item's `insert`, as `NSString` counts (UTF-16). It holds the caret, or nothing is
    /// listed.
    public var range: NSRange
    /// What's typed so far, which the list matches the items' labels against: nothing typed, it lists every item as
    /// offered.
    public var query: String
    public var items: [CaretCompletion]

    public init(range: NSRange, query: String, items: [CaretCompletion]) {
        self.range = range
        self.query = query
        self.items = items
    }
}

/// One candidate: what its row says, and what a pick puts in the text.
public struct CaretCompletion: Equatable, Sendable {
    /// What its row shows, and what's typed is matched against.
    public var label: String
    /// A line about it, after the label in its row; "" for none.
    public var detail: String
    /// What replaces the completions' `range` once it's picked.
    public var insert: String
    /// Within `insert` (UTF-16): where the caret goes once it's in (an empty range), or what's selected, to be typed over.
    public var selection: NSRange
    /// Where the pick leaves the caret has completions of its own: the list asks again there at once, and opens if
    /// anything's offered.
    public var reopens: Bool
    /// Whether it matters where it's offered: of the items what's typed matches alike, those that do come first.
    public var isRelevant: Bool
    /// An action rather than words to put in ("New type Problem"): a list that picks only actions on Return
    /// (`CaretList.returnPicks`, `.actionsOnly`) does it on Return, where it never picks words.
    public var isAction: Bool
    /// The color of a capsule its row is drawn in (an enum's purple), nil for a plain row.
    public var chip: NSColor?
    /// Whether the list highlights it once it's listed, wherever the order puts it, so Return does it (the action nothing else is
    /// called so: "New type Refund" while no type's name is or starts with `Refund`). The first item is highlighted otherwise.
    public var isDefault: Bool

    /// `selection` nil: the caret after `insert`.
    public init(label: String, detail: String = "", insert: String, selection: NSRange? = nil, reopens: Bool = false, isRelevant: Bool = true,
                isAction: Bool = false, chip: NSColor? = nil, isDefault: Bool = false) {
        self.label = label
        self.detail = detail
        self.insert = insert
        self.selection = selection ?? NSRange(location: (insert as NSString).length, length: 0)
        self.reopens = reopens
        self.isRelevant = isRelevant
        self.isAction = isAction
        self.chip = chip
        self.isDefault = isDefault
    }
}

extension CaretCompletions {
    /// An item as the list shows it: with its label's characters what's typed matched.
    public struct Listed: Equatable, Sendable {
        public let item: CaretCompletion
        public let matched: [Range<Int>]

        public init(item: CaretCompletion, matched: [Range<Int>]) {
            self.item = item
            self.matched = matched
        }
    }

    /// How well what's typed matches each of the labels: a score (higher is better) and the characters matched, nil for
    /// a label it doesn't match. The one matcher's (FuzzyMatching's `FuzzyMatcher.matches`), which the host passes in.
    public typealias Scoring = (_ query: String, _ labels: [String]) -> [(score: Int, matched: [Range<Int>])?]

    /// What the list shows, in order: every item as offered while nothing's typed (`isBlank` says what's nothing); else
    /// the items what's typed matches, the best score first, then those that matter, then as offered; an action
    /// ("New type Problem") after every word, whatever its score. Nothing, where nothing matches.
    public func listed(isBlank: (String) -> Bool = { $0.isEmpty }, scoring: Scoring) -> [Listed] {
        guard !isBlank(query) else { return items.map { Listed(item: $0, matched: []) } }
        let matches = scoring(query, items.map(\.label))
        let found = items.indices.compactMap { i in matches[i].map { (index: i, match: $0) } }
        return found.sorted { a, b in
            if items[a.index].isAction != items[b.index].isAction { return !items[a.index].isAction }
            if a.match.score != b.match.score { return a.match.score > b.match.score }
            if items[a.index].isRelevant != items[b.index].isRelevant { return items[a.index].isRelevant }
            return a.index < b.index
        }
        .map { Listed(item: items[$0.index], matched: $0.match.matched) }
    }
}
