import Foundation
import FuzzyMatching

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

/// The picker's weights: the tiers a match falls in (every caret list's, `FuzzyRanking`), and
/// what's added or taken away for the shape (a placeholder label, a recent pick, nearness). Pure,
/// so nonisolated.
public enum MentionRanking {
    /// The label is the query.
    public static let exact = FuzzyRanking.exact
    /// The label starts with the query.
    public static let prefix = FuzzyRanking.prefix
    /// Each word of the query starts a word of the label, in order ("gro li", "Grocery List").
    public static let wordPrefixes = FuzzyRanking.wordPrefixes
    /// The query is in the label, anywhere.
    public static let substring = FuzzyRanking.substring
    /// The query's characters are in the label in order ("grcy"): at most this.
    public static let subsequence = FuzzyRanking.subsequence
    /// A word of the label starts with the query but for one typo, for a query this long or longer
    /// that matched nothing better.
    public static let typo = FuzzyRanking.typo
    public static let typoMinimumQuery = FuzzyRanking.typoMinimumQuery
    /// The typo pass runs only when the other tiers found fewer than this many shapes.
    public static let typoPassBelow = FuzzyRanking.typoPassBelow

    /// Added for a recent pick: this for the latest, less for each pick back.
    public static let recentBonus = 100
    /// Added for nearness to the text's shape: this at no distance, half at `nearnessScale` world
    /// units; worked out for the best `nearnessCandidates` only.
    public static let nearnessBonus = 50
    public static let nearnessScale: Double = 1000
    public static let nearnessCandidates = 200

    /// The most shapes a query lists, and an empty one of a command's kinds (`candidates`' `kinds`).
    public static let maxMatches = 50
    /// The most an empty query lists in each of its sections, but Nearby of a command's kinds.
    public static let recentShown = 4
    public static let nearbyShown = 4
    /// A scope that admits this many shapes or fewer (or an eighth of the catalog) is read whole for the
    /// shapes nearest the text, rather than by growing squares around it.
    public static let narrowScope = 512
    /// The picks kept for "Recent" and the recent bonus.
    public static let recentKept = 20
}

/// Fuzzy matching of what's typed after `@` against shapes' labels: every caret list's matcher
/// (`FuzzyMatcher`, DetailPanel's), which the catalog's two passes over its folded labels use
/// too (`MentionState.candidates`).
public enum MentionMatcher {
    /// How many words `query` has, as the picker splits them (`PathMatcher`: on whitespace, the words past the
    /// eighth one): the words before the last may name a shape's containers, so a longer query narrows what a
    /// shorter one found only among queries of as many words (`MentionCandidates.words`).
    public static func words(in query: String) -> Int { PathMatcher(query).pieceCount }

    /// How `query` matches `label`; nil for not at all.
    public static func match(_ query: String, in label: String) -> MentionMatch? {
        FuzzyMatcher.match(query, in: label).map { MentionMatch(score: $0.score, matched: $0.matched) }
    }
}
