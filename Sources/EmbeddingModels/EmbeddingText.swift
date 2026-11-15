import Foundation

/// The text a note is embedded by, character for character as the spike's `texts.mjs` writes it (the
/// layout spike, `docs/spikes/semantic-layout`), so vectors kept from it still mean what they did: its
/// title, then its words, with code names split into words (AdornmentLabel becomes Adornment Label).
///
///     title = (title || '').replace(/^(\S+)\.[A-Za-z][A-Za-z0-9]{0,7}$/, '$1')
///     body  = (text || description || '').slice(0, 900)
///     text  = split(title + '. ' + body).replace(/\s+/g, ' ').trim()
///
/// JavaScript's rules, not Foundation's, where the two differ: strings are counted in UTF-16 units,
/// `\s` is the set `isJavaScriptSpace` lists (not `.whitespacesAndNewlines`, which has U+0085 and lacks
/// U+FEFF), and `$` without the `m` flag matches only at the very end (ICU's matches before a final line
/// break too, so a title ending in a newline would lose its extension). The one deviation: a cut that
/// falls between the halves of a surrogate pair drops the pair's first half, where JavaScript keeps it
/// and sends invalid UTF-16.
public enum EmbeddingText {
    /// How much of a note's words are read, in UTF-16 units.
    public static let wordsLimit = 900

    /// The text of a note with `title` and `words` (nil: none). Never empty: nothing at all is ".".
    public static func of(title: String?, words: String?) -> String {
        let named = strippingExtension(title ?? "")
        let body = prefix(words ?? "", units: wordsLimit)
        return collapsingSpace(split(named + ". " + body))
    }

    /// `title` without a trailing file extension (a dot, a letter and up to seven letters or digits)
    /// when it looks like a file name: no whitespace in it, and something before the dot.
    static func strippingExtension(_ title: String) -> String {
        let units = Array(title.utf16)
        guard let dot = units.lastIndex(of: 0x2E), dot > 0 else { return title }
        let extensionUnits = units[(dot + 1)...]
        guard (1...8).contains(extensionUnits.count), isLetter(extensionUnits[extensionUnits.startIndex]),
              extensionUnits.dropFirst().allSatisfy({ isLetter($0) || isDigit($0) }),
              !units.contains(where: isJavaScriptSpace) else { return title }
        return String(decoding: units[..<dot], as: UTF16.self)
    }

    /// The first `count` UTF-16 units of `text`, less a first half of a surrogate pair the cut would
    /// leave alone.
    static func prefix(_ text: String, units count: Int) -> String {
        let units = Array(text.utf16)
        guard units.count > count else { return text }
        var end = count
        if UTF16.isLeadSurrogate(units[end - 1]) { end -= 1 }
        return String(decoding: units[..<end], as: UTF16.self)
    }

    /// Code names split into words: a lower-case letter or digit before a capital, the last capital of
    /// a run before a capital and a lower-case letter, and backticks and underscores, each a space.
    static func split(_ text: String) -> String {
        var split = replacing(Patterns.lowerThenUpper, in: text)
        split = replacing(Patterns.runThenWord, in: split)
        // Units, not Characters: a backtick with a combining mark after it is one Character.
        return String(decoding: split.utf16.map { $0 == 0x60 || $0 == 0x5F ? 0x20 : $0 }, as: UTF16.self)
    }

    private static func replacing(_ pattern: NSRegularExpression, in text: String) -> String {
        // The whole string's UTF-16 range: NSRange counts UTF-16 units, never Characters.
        pattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: (text as NSString).length), withTemplate: "$1 $2")
    }

    /// Every run of JavaScript whitespace a single space, none at either end.
    static func collapsingSpace(_ text: String) -> String {
        var out: [UInt16] = []
        out.reserveCapacity(text.utf16.count)
        var inSpace = false
        for unit in text.utf16 {
            if isJavaScriptSpace(unit) {
                inSpace = true
            } else {
                if inSpace, !out.isEmpty { out.append(0x20) }
                inSpace = false
                out.append(unit)
            }
        }
        return String(decoding: out, as: UTF16.self)
    }

    /// What JavaScript's `\s` matches in a string without the `u` flag: U+0009 to U+000D, U+0020,
    /// U+00A0, U+1680, U+2000 to U+200A, U+2028, U+2029, U+202F, U+205F, U+3000 and U+FEFF.
    static func isJavaScriptSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF: true
        default: false
        }
    }

    private static func isLetter(_ unit: UInt16) -> Bool { (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit) }
    private static func isDigit(_ unit: UInt16) -> Bool { (0x30...0x39).contains(unit) }

    /// The two splits' patterns, exactly as `texts.mjs` writes them: ASCII classes, matched leftmost and
    /// without overlap, as JavaScript matches them.
    private enum Patterns {
        static let lowerThenUpper = make("([a-z0-9])([A-Z])")
        static let runThenWord = make("([A-Z]+)([A-Z][a-z])")

        private static func make(_ pattern: String) -> NSRegularExpression {
            do {
                return try NSRegularExpression(pattern: pattern)
            } catch {
                fatalError("the pattern \(pattern) doesn't compile")
            }
        }
    }
}
