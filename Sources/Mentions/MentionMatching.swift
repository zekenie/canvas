import DetailPanel
import Foundation

/// How well a query matches a label: its score (the tier's, up to `MentionRanking.exact`), and the
/// label's matched characters, as ranges of `Character` offsets, for the picker to set in semibold.
public struct MentionMatch: Hashable, Sendable {
    public let score: Int
    public let matched: [Range<Int>]

    public init(score: Int, matched: [Range<Int>]) {
        self.score = score
        self.matched = matched
    }
}

/// The picker's weights: the tiers a match falls in (every caret list's, `CaretListRanking`), and
/// what's added or taken away for the shape (a placeholder label, a recent pick, nearness). Pure,
/// so nonisolated.
public enum MentionRanking {
    /// The label is the query.
    public static let exact = CaretListRanking.exact
    /// The label starts with the query.
    public static let prefix = CaretListRanking.prefix
    /// Each word of the query starts a word of the label, in order ("gro li", "Grocery List").
    public static let wordPrefixes = CaretListRanking.wordPrefixes
    /// The query is in the label, anywhere.
    public static let substring = CaretListRanking.substring
    /// The query's characters are in the label in order ("grcy"): at most this.
    public static let subsequence = CaretListRanking.subsequence
    /// A word of the label starts with the query but for one typo, for a query this long or longer
    /// that matched nothing better.
    public static let typo = CaretListRanking.typo
    public static let typoMinimumQuery = CaretListRanking.typoMinimumQuery
    /// The typo pass runs only when the other tiers found fewer than this many shapes.
    public static let typoPassBelow = CaretListRanking.typoPassBelow

    /// Added for a recent pick: this for the latest, less for each pick back.
    public static let recentBonus = 100
    /// Added for nearness to the text's shape: this at no distance, half at `nearnessScale` world
    /// units; worked out for the best `nearnessCandidates` only.
    public static let nearnessBonus = 50
    public static let nearnessScale: Double = 1000
    public static let nearnessCandidates = 200

    /// The most shapes a query lists.
    public static let maxMatches = 50
    /// The most an empty query lists in each of its sections.
    public static let recentShown = 4
    public static let nearbyShown = 4
    /// The picks kept for "Recent" and the recent bonus.
    public static let recentKept = 20
}

/// Fuzzy matching of what's typed after `@` against shapes' labels: every caret list's matcher
/// (`CaretListMatcher`, DetailPanel's), which the catalog's two passes over its folded labels use
/// too (`MentionState.candidates`).
public enum MentionMatcher {
    /// How `query` matches `label`; nil for not at all.
    public static func match(_ query: String, in label: String) -> MentionMatch? {
        CaretListMatcher.match(query, in: label).map { MentionMatch(score: $0.score, matched: $0.matched) }
    }
}
