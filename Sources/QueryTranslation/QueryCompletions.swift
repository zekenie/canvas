import Canvas
import DetailPanel
import Foundation
import Queries

/// What can be typed in a stored query a panel edits as code (a rule chip's, a constraint's): the words, after a `:`, else the
/// kinds. Lifted out of the rule chips', so every host of words that become a query offers the same.
public enum QueryCompletions {
    /// The completions of the engine's vocabulary: its words (but those that read what the person has selected or looks at),
    /// each with its colon, and `extraWords` (a host's own, as a bound query's `:scope`), listed as given; the kinds, for what's
    /// typed with no colon.
    @MainActor
    public static func completer(for vocabulary: QueryVocabulary, extraWords: [(word: String, summary: String)] = []) -> DetailCodeCompleting {
        // A word is listed without its colon (`edge-to`), and the range a pick replaces starts at the colon.
        let words = vocabulary.words.filter { !$0.readsEditor }.map { DetailCodeCompletion(label: ":" + $0.word, detail: $0.summary, insert: ":" + $0.word) }
            + extraWords.map { DetailCodeCompletion(label: $0.word, detail: $0.summary, insert: $0.word) }
        let kinds = vocabulary.kinds.map { DetailCodeCompletion(label: $0.kind.rawValue, detail: $0.label, insert: $0.kind.rawValue) }
        return { text, caret in
            let units = Array(text.utf16)
            guard caret <= units.count else { return nil }
            var start = caret
            while start > 0, let scalar = Unicode.Scalar(units[start - 1]),
                  CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == ":" {
                start -= 1
                if scalar == ":" { break }
            }
            let token = String(utf16CodeUnits: Array(units[start..<caret]), count: caret - start)
            let range = NSRange(location: start, length: caret - start)
            if token.hasPrefix(":") { return DetailCodeCompletions(range: range, query: token, items: words) }
            guard !token.isEmpty else { return nil }
            return DetailCodeCompletions(range: range, query: token, items: kinds)
        }
    }
}
