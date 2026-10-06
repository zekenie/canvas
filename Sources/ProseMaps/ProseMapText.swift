import Foundation

/// Finding a map's ends in its texts, and cutting a part out to show: pure, and nonisolated.
public enum ProseMapText {
    /// Where each of `quotes` is in `prose`, in order: the first place no earlier one holds, looked
    /// for from where the last one found ends, then from the start; at word boundaries (neither end
    /// inside a word) before anywhere; as written before ignoring case. Nil for a quote that isn't
    /// there (or is empty). The model lists links in the prose's order, so words written twice go to
    /// their places in turn.
    public static func anchor(_ quotes: [String], in prose: String) -> [Range<String.Index>?] {
        var placed: [Range<String.Index>] = []
        var cursor = prose.startIndex
        return quotes.map { quote in
            guard !quote.isEmpty else { return nil }
            for options in [String.CompareOptions.literal, [.literal, .caseInsensitive]] {
                for start in [cursor, prose.startIndex] {
                    for bounded in [true, false] {
                        var from = start
                        while from < prose.endIndex, let found = prose.range(of: quote, options: options, range: from..<prose.endIndex) {
                            if !placed.contains(where: { $0.overlaps(found) }), !bounded || isWhole(found, in: prose) {
                                placed.append(found)
                                cursor = found.upperBound
                                return found
                            }
                            from = prose.index(after: found.lowerBound)
                        }
                    }
                }
            }
            return nil
        }
    }

    /// Whether neither end of `range` is inside a word: at each end, the characters either side
    /// aren't both letters, digits or underscores.
    private static func isWhole(_ range: Range<String.Index>, in text: String) -> Bool {
        func wordy(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        if range.lowerBound > text.startIndex, wordy(text[text.index(before: range.lowerBound)]), wordy(text[range.lowerBound]) { return false }
        if range.upperBound < text.endIndex, wordy(text[range.upperBound]), wordy(text[text.index(before: range.upperBound)]) { return false }
        return true
    }

    /// Where `quote` is written in `text`, if it's written there exactly once: as written, but that a
    /// run of whitespace in it matches any run there, so a quote of code survives its lines being
    /// broken or indented anew. Nil for a quote that's blank, absent, or written more than once.
    public static func find(_ quote: String, in text: String) -> Range<String.Index>? {
        let words = quote.split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty,
              let pattern = try? NSRegularExpression(pattern: words.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s+"))
        else { return nil }
        let whole = NSRange(text.startIndex..., in: text)
        guard let first = pattern.firstMatch(in: text, range: whole) else { return nil }
        // Written again from anywhere after where it starts, overlapping it or not ("x + x" in "x + x + x").
        let after = first.range.location + 1
        if after < whole.length, pattern.firstMatch(in: text, range: NSRange(location: after, length: whole.length - after)) != nil { return nil }
        return Range(first.range, in: text)
    }

    /// A part of `text` as a person reads it (a link's, `ProseMap.Link.inTarget`): its text as
    /// written, each line after the first less the indent of the line it starts on, so it reads as
    /// though written at the left margin.
    public static func excerpt(_ range: Range<String.Index>, of text: String) -> String {
        let lineStart = text.utf8[..<range.lowerBound].lastIndex(of: UInt8(ascii: "\n")).map { text.utf8.index(after: $0) } ?? text.startIndex
        let indent = text.utf8[lineStart..<range.lowerBound].prefix { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }.count
        let part = String(text[range])
        guard indent > 0 else { return part }
        return part.split(separator: "\n", omittingEmptySubsequences: false).enumerated().map { index, line in
            guard index > 0 else { return String(line) }
            return String(line.dropFirst(min(line.prefix { $0 == " " || $0 == "\t" }.count, indent)))
        }.joined(separator: "\n")
    }
}
