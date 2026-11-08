import AppKit
import FuzzyMatching
import TextEditing

// A code editor's completions (`DetailCodeEditor`'s `completions:`): a plugin says what can be
// typed at the caret, in its language, and the editor lists it there, in the app's one caret list
// (`CaretList`, as Mentions' `@` picker is), ranked by what's typed with the one matcher
// (`FuzzyMatcher`), and puts a pick in. The language is the plugin's; the keys, the list and
// the ranking are the panel's.

/// What can be typed at a code editor's caret: asked with the text and the caret (UTF-16, as
/// `NSString` counts), nil where nothing can. It's asked as the list opens and after every
/// keystroke and move of the caret while it's open, so keep it to what the caret's place costs,
/// not the text's length.
public typealias DetailCodeCompleting = @MainActor (_ text: String, _ caret: Int) -> DetailCodeCompletions?

/// What a code editor's provider offers at a caret: TextEditing's `CaretCompletions`, every candidate in the order
/// offered, unfiltered (the list matches them against what's typed itself), which a row written as a line offers too.
public typealias DetailCodeCompletions = CaretCompletions

/// One candidate: what its row says, and what a pick puts in the text (TextEditing's `CaretCompletion`).
public typealias DetailCodeCompletion = CaretCompletion

extension CaretCompletions {
    /// What the list shows, in order, ranked by the one matcher (`FuzzyMatcher`): every item as offered while nothing's
    /// typed; else the items what's typed matches, the best tier first (`FuzzyRanking`), then those that matter, then as
    /// offered. Nothing, where nothing matches.
    func listed() -> [Listed] {
        listed(isBlank: { FuzzyMatcher.Query($0).isEmpty }) { query, labels in
            FuzzyMatcher.matches(query, in: labels).map { $0.map { (score: $0.score, matched: $0.matched) } }
        }
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
