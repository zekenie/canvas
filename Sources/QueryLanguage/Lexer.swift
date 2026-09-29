/// Reads a query's characters for the parser: whitespace and comments, identifiers, strings, bare
/// values and ids, as it asks for them (what a run of characters is depends on where it is: `2026-10-01`
/// is a value after an operator and nothing elsewhere). Positions are indexes into the Characters it
/// reads, and a span is one of those plus `base`, so a raw argument read again (`SelectorList(argumentOf:)`)
/// says where it is in the whole query.
struct Lexer {
    let characters: [Character]
    /// Added to every position a span holds.
    let base: Int
    /// Whether these are the whole query as sent, so a hint may be the query with its closer added.
    let isWholeQuery: Bool
    var position = 0

    /// The whole query, or, `at` an offset, a part of it read again (a raw argument).
    init(_ text: String, at base: Int? = nil) {
        characters = Array(text)
        self.base = base ?? 0
        isWholeQuery = base == nil
    }

    var atEnd: Bool { position >= characters.count }
    var current: Character? { position < characters.count ? characters[position] : nil }

    func peek(_ ahead: Int) -> Character? {
        let index = position + ahead
        return index < characters.count ? characters[index] : nil
    }

    func text(_ range: Range<Int>) -> String { String(characters[range]) }

    /// A span of positions, in the whole query.
    func span(_ range: Range<Int>) -> QuerySpan { QuerySpan(offset: base + range.lowerBound, length: range.count) }

    /// The query with `closer` added, for a hint about what isn't closed; nil for a raw argument read
    /// again, which isn't the whole query. `trimming` leaves out the whitespace at its end first.
    func closed(with closer: String, trimming: Bool = true) -> String? {
        guard isWholeQuery else { return nil }
        var end = characters.count
        if trimming { while end > 0, characters[end - 1].isWhitespace { end -= 1 } }
        return text(0..<end) + closer
    }

    // MARK: Characters

    static func startsIdentifier(_ character: Character) -> Bool { character.isLetter || character == "_" }
    static func continuesIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "-" || character == "_"
    }
    static let quotes: Set<Character> = ["\"", "'"]
    /// Quotes a text editor may have put in, never the language's.
    static let curlyQuotes: Set<Character> = ["\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}"]

    var atIdentifier: Bool { current.map(Self.startsIdentifier) ?? false }
    var atQuote: Bool { current.map(Self.quotes.contains) ?? false }
    var atComment: Bool { current == "/" && peek(1) == "*" }

    // MARK: Reading

    /// Skips whitespace and comments (a comment counts as whitespace), and says whether it skipped any.
    mutating func skipSpace() throws(QueryError) -> Bool {
        let start = position
        while let character = current {
            if character.isWhitespace {
                position += 1
            } else if atComment {
                let open = position
                position += 2
                while !atEnd, !(current == "*" && peek(1) == "/") { position += 1 }
                guard !atEnd else {
                    throw QueryError(.syntax, "/* isn't closed.", hint: closed(with: "*/", trimming: false), span: span(open..<characters.count))
                }
                position += 2
            } else {
                break
            }
        }
        return position > start
    }

    /// An identifier at the position: a letter or `_`, then letters, digits, `-` and `_`.
    mutating func identifier() -> String {
        let start = position
        if atIdentifier { position += 1 }
        while let character = current, Self.continuesIdentifier(character) { position += 1 }
        return text(start..<position)
    }

    /// How long the identifier at the position is, without reading it.
    var identifierLength: Int {
        var copy = self
        return copy.identifier().count
    }

    /// A string at the position, `"…"` or `'…'`, its escapes undone: `\"`, `\'`, `\\` and `\n`.
    mutating func string() throws(QueryError) -> String {
        let start = position
        let quote = characters[position]
        position += 1
        var value = ""
        while let character = current {
            if character == quote {
                position += 1
                guard value.count <= QueryLimits.stringCharacters else {
                    throw QueryError(.tooLong, "The string is \(grouped(value.count)) characters long; a string is at most \(grouped(QueryLimits.stringCharacters)).",
                                     span: span(start..<position))
                }
                return value
            }
            if character.isNewline { throw lineBreak(from: start) }
            if character == "\\" {
                guard let next = peek(1) else {
                    position += 1
                    break
                }
                switch next {
                case "\"", "'", "\\": value.append(next)
                case "n": value.append("\n")
                default:
                    if next.isNewline {
                        position += 1
                        throw lineBreak(from: start)
                    }
                    throw QueryError(.syntax, "\\\(next) isn't an escape.",
                                     hint: #"In quotes, write \" or \' for a quote, \\ for a backslash and \n for a line break."#,
                                     span: span(position..<(position + 2)))
                }
                position += 2
                continue
            }
            value.append(character)
            position += 1
        }
        throw QueryError(.syntax, "\(quote) isn't closed.", hint: closed(with: String(quote), trimming: false), span: span(start..<characters.count))
    }

    /// A string that reaches a line break at the position, from its opening quote.
    private func lineBreak(from start: Int) -> QueryError {
        QueryError(.syntax, "A string can't hold a line break.", hint: #"Close it before the line ends; \n is a line break inside it."#,
                   span: span(start..<position))
    }

    /// A bare value at the position: a run of characters other than whitespace, `]` and quotes,
    /// up to a comment.
    mutating func bare() -> String {
        let start = position
        while let character = current, !character.isWhitespace, character != "]", !Self.quotes.contains(character), !atComment {
            position += 1
        }
        return text(start..<position)
    }
}

/// Lowercased, ASCII letters only: the language's words ignore ASCII case, as CSS's do.
func asciiLowercased(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
        (65...90).contains(scalar.value) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
    }))
}

extension String {
    var trimmingTrailingWhitespace: String {
        var end = endIndex
        while end > startIndex, self[index(before: end)].isWhitespace { end = index(before: end) }
        return String(self[..<end])
    }

    var trimmingWhitespace: String {
        String(drop { $0.isWhitespace }).trimmingTrailingWhitespace
    }
}

/// A count as a message writes it: 8,192.
func grouped(_ number: Int) -> String {
    let digits = String(number.magnitude)
    var out = ""
    for (index, digit) in digits.enumerated() {
        if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
        out.append(digit)
    }
    return number < 0 ? "-" + out : out
}
