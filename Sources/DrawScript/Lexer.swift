// Modified from reladraw's src/lexer.ts (Apache-2.0; THIRD_PARTY_NOTICES.md).

/// One token of a line.
struct Token: Equatable {
    enum Kind: Equatable {
        /// Runs to whitespace, `"`, `//`, `(` or `)`: a kind, a direction, a value.
        case word
        /// `"…"`: its text with the escapes undone.
        case quoted
        /// A word ending in `:` (longer than `:`): its text without the colon. Only a key opens an
        /// attribute.
        case key
        /// After a key, `[…]` or `{…}` to the matching bracket: its text as written.
        case json
        case open, close, comma
    }

    var kind: Kind
    var text: String
    /// As written, for quoting back.
    var raw: String

    func isWord(_ word: String) -> Bool { kind == .word && text == word }
}

/// A line cut into tokens, and the line as written up to its comment, trimmed.
struct LexedLine {
    var tokens: [Token]
    var text: String
}

/// Cuts a line into tokens. Spaces and tabs separate them; `//` outside a quoted string or a JSON
/// value starts a comment; `#` is an ordinary character. A trailing comma on a word is a separator
/// of its own (`"A", "B"`, `urgent, quiet`), as `and` is.
enum Lexer {
    /// What starts a comment.
    static let comment = "//"
    static let openingQuotes: Set<Character> = ["\u{201C}", "\u{2018}", "'", "\u{201D}", "\u{2019}"]

    static func lex(_ line: String, number: Int) throws(ScriptError) -> LexedLine {
        let characters = Array(line)
        var tokens: [Token] = []
        var index = 0
        var end = characters.count
        func refuse(_ message: String, hint: String? = nil) -> ScriptError {
            ScriptError(line: number, reason: .syntax, message, hint: hint, statement: String(line).trimmingSpaces)
        }
        func isCommentStart(_ at: Int) -> Bool { characters[at] == "/" && at + 1 < characters.count && characters[at + 1] == "/" }

        scan: while index < characters.count {
            let character = characters[index]
            if character == " " || character == "\t" || character.isWhitespace && !character.isNewline {
                index += 1
                continue
            }
            if isCommentStart(index) {
                end = index
                break scan
            }
            switch character {
            case "(":
                tokens.append(Token(kind: .open, text: "(", raw: "("))
                index += 1
            case ")":
                tokens.append(Token(kind: .close, text: ")", raw: ")"))
                index += 1
            case "\"":
                let start = index
                var text = ""
                index += 1
                var closed = false
                while index < characters.count {
                    let next = characters[index]
                    if next == "\\" {
                        guard index + 1 < characters.count else { break }
                        switch characters[index + 1] {
                        case "\"": text.append("\"")
                        case "\\": text.append("\\")
                        case "n": text.append("\n")
                        case "t": text.append("\t")
                        default:
                            throw refuse("\"\\\(characters[index + 1])\" isn't an escape",
                                         hint: "inside quotes, write \\\" for a quote, \\\\ for a backslash, \\n for a new line or \\t for a tab")
                        }
                        index += 2
                        continue
                    }
                    if next == "\"" {
                        closed = true
                        index += 1
                        break
                    }
                    text.append(next)
                    index += 1
                }
                guard closed else {
                    throw refuse("\(String(characters[start...])) isn't closed on its line", hint: "a quoted title or text ends with \" on the same line")
                }
                tokens.append(Token(kind: .quoted, text: text, raw: String(characters[start..<index])))
            case "[" where tokens.last?.kind == .key, "{" where tokens.last?.kind == .key:
                let start = index
                var depth = 0
                var inString = false
                while index < characters.count {
                    let next = characters[index]
                    if inString {
                        if next == "\\" { index += 1 } else if next == "\"" { inString = false }
                    } else if next == "\"" {
                        inString = true
                    } else if next == "[" || next == "{" {
                        depth += 1
                    } else if next == "]" || next == "}" {
                        depth -= 1
                        if depth == 0 {
                            index += 1
                            break
                        }
                    }
                    index += 1
                }
                guard depth == 0, !inString else {
                    throw refuse("\(String(characters[start...]).trimmingSpaces) opens a \(character) that isn't closed on its line",
                                 hint: "a JSON value is written on one line")
                }
                let json = String(characters[start..<index])
                tokens.append(Token(kind: .json, text: json, raw: json))
            default:
                if openingQuotes.contains(character) {
                    var close = index + 1
                    while close < characters.count, !openingQuotes.contains(characters[close]) { close += 1 }
                    let inside = close < characters.count ? String(characters[(index + 1)..<close])
                        : String(characters[(index + 1)...].prefix { !$0.isWhitespace })
                    throw refuse("titles and text are in straight double quotes: \(quote(inside))")
                }
                let start = index
                while index < characters.count {
                    let next = characters[index]
                    if next.isWhitespace || next == "\"" || next == "(" || next == ")" || isCommentStart(index) { break }
                    index += 1
                }
                var word = String(characters[start..<index])
                var comma = false
                if word.count > 1, word.hasSuffix(",") {
                    word.removeLast()
                    comma = true
                }
                if word == "," {
                    tokens.append(Token(kind: .comma, text: ",", raw: ","))
                } else if word.count > 1, word.hasSuffix(":") {
                    tokens.append(Token(kind: .key, text: String(word.dropLast()), raw: word))
                } else {
                    tokens.append(Token(kind: .word, text: word, raw: word))
                }
                if comma { tokens.append(Token(kind: .comma, text: ",", raw: ",")) }
            }
        }
        return LexedLine(tokens: tokens, text: String(characters[0..<end]).trimmingSpaces)
    }
}

extension String {
    /// Without the whitespace at either end.
    var trimmingSpaces: String {
        var characters = Substring(self)
        while characters.first?.isWhitespace == true { characters.removeFirst() }
        while characters.last?.isWhitespace == true { characters.removeLast() }
        return String(characters)
    }
}
