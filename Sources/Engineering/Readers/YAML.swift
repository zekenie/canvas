import Foundation
import Types

// YAML, a subset, read into Types' ordered `SchemaValue`, so a YAML file and a JSON one (through Types' `JSONReader`) reach the
// OpenAPI reader as one ordered tree and an API's endpoints and a type's fields keep the order they were written in. The subset is
// what OpenAPI files and config files are written in (canvas-ingest's lenskit reads the same, in Python): block mappings and
// sequences (a sequence may sit at its key's indent), YAML 1.2's core-schema scalars (null, booleans, integers in decimal, octal
// and hex, floats with .inf and .nan; anything else a string), single- and double-quoted strings (over several lines too), block
// scalars `|` and `>` with their chomping (`-`, `+`) and an indentation digit, flow `[…]` and `{…}` on one line, comments, a leading
// `---` (and `%` directives before it), plain scalars folded over lines, and keys always strings (`200:` is "200"). A key written
// twice keeps its first place and its last value, as Types' JSON does. What it can't read is refused whole, with the line it
// stopped at: anchors and aliases (`&a`, `*a`), tags (`!!str`), `?` keys, flow collections over several lines, tabs in an indent,
// a second document. A paste of what it refuses isn't recognized, and ⌘V does what it would do without it.

/// Why YAML didn't read: what, and on which line (from 1).
public struct YAMLError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var line: Int

    public var description: String { "\(message) (line \(line))" }
}

/// The YAML subset's reader.
public enum YAMLReader {
    /// Mappings and sequences nest at most this deep; deeper is refused, so no text can exhaust the stack.
    public static let maxDepth = 128

    /// `text`'s one document as an ordered value: nil for a text with nothing in it.
    public static func read(_ text: String) throws(YAMLError) -> SchemaValue? {
        var parser = YAMLParser(text)
        return try parser.document()
    }
}

/// A line of the text: its number (from 1), its indent (spaces) and what follows it, the line break gone.
private struct YAMLLine {
    var number: Int
    var indent: Int
    var text: String
    /// Whether it says nothing: blank, or a comment alone.
    var isBlank: Bool { text.isEmpty || text.hasPrefix("#") }
}

private struct YAMLParser {
    var lines: [YAMLLine]
    var at = 0
    var depth = 0

    init(_ text: String) {
        var lines: [YAMLLine] = [], raw: [String] = []
        var number = 0
        text.enumerateLines { line, _ in
            number += 1
            raw.append(line)
            let indent = line.prefix { $0 == " " }.count
            var rest = String(line.dropFirst(indent))
            // Whitespace at a line's end says nothing (a block scalar's own lines keep theirs: `raw`).
            while rest.last == " " || rest.last == "\t" { rest.removeLast() }
            lines.append(YAMLLine(number: number, indent: indent, text: rest))
        }
        self.lines = lines
        self.raw = raw
    }

    /// The text's lines as written, for a block scalar, whose spaces are its own.
    let raw: [String]

    func fail(_ message: String, _ line: Int? = nil) -> YAMLError {
        YAMLError(message: message, line: line ?? (at < lines.count ? lines[at].number : lines.last?.number ?? 1))
    }

    // MARK: The document

    mutating func document() throws(YAMLError) -> SchemaValue? {
        // Directives and a `---` before the document; nothing but blank lines may come before them.
        skipBlank()
        while at < lines.count, lines[at].indent == 0, lines[at].text.hasPrefix("%") {
            at += 1
            skipBlank()
        }
        if at < lines.count, lines[at].indent == 0, isMarker(lines[at].text, "---") {
            let rest = lines[at].text.dropFirst(3).trimmingCharacters(in: .whitespaces)
            if rest.isEmpty || rest.hasPrefix("#") {
                at += 1
            } else {
                // `--- value` on the marker's line: the document is that line.
                lines[at].text = rest
                lines[at].indent = 4
            }
        }
        skipBlank()
        guard at < lines.count, !isEnd(lines[at]) else { return nil }
        let value = try node(above: -1)
        skipBlank()
        if at < lines.count {
            let line = lines[at]
            if line.indent == 0, isMarker(line.text, "...") {
                return value
            }
            if line.indent == 0, isMarker(line.text, "---") { throw fail("a second document isn't read") }
            throw fail("this line doesn't belong where it is")
        }
        return value
    }

    func isMarker(_ text: String, _ marker: String) -> Bool {
        text == marker || text.hasPrefix(marker + " ") || text.hasPrefix(marker + "\t")
    }

    func isEnd(_ line: YAMLLine) -> Bool {
        line.indent == 0 && (isMarker(line.text, "...") || isMarker(line.text, "---"))
    }

    mutating func skipBlank() {
        while at < lines.count, lines[at].isBlank { at += 1 }
    }

    /// The next line that says something, without moving past it.
    mutating func next() -> YAMLLine? {
        skipBlank()
        guard at < lines.count, !isEnd(lines[at]) else { return nil }
        return lines[at]
    }

    // MARK: Block nodes

    /// The node that starts on the next line that says something, indented past `parent`.
    mutating func node(above parent: Int) throws(YAMLError) -> SchemaValue {
        guard let line = next(), line.indent > parent else { return .null }
        depth += 1
        defer { depth -= 1 }
        guard depth < YAMLReader.maxDepth else { throw fail("nested too deep") }
        if line.text.hasPrefix("\t") { throw fail("a tab in an indent isn't read") }
        if isItem(line.text) { return try sequence(at: line.indent) }
        if try entry(line.text) != nil { return try mapping(at: line.indent) }
        // A scalar alone: a document that is one, or a value on the line after its key.
        at += 1
        return try scalar(line.text, line: line, parent: parent)
    }

    /// Whether a line is a sequence's item: `-` alone, or followed by a space.
    func isItem(_ text: String) -> Bool { text == "-" || text.hasPrefix("- ") || text.hasPrefix("-\t") }

    mutating func sequence(at indent: Int) throws(YAMLError) -> SchemaValue {
        var items: [SchemaValue] = []
        while let line = next(), line.indent == indent, isItem(line.text) {
            if line.text.hasPrefix("\t") { throw fail("a tab in an indent isn't read") }
            let rest = String(line.text.dropFirst()).drop { $0 == " " }
            if rest.isEmpty || rest.hasPrefix("#") {
                at += 1
                items.append(try node(above: indent))
                continue
            }
            // What follows the dash is a node at its own column: the line is read again as starting there.
            let column = indent + (line.text.count - rest.count)
            lines[at] = YAMLLine(number: line.number, indent: column, text: String(rest))
            items.append(try node(above: indent))
        }
        if let line = next(), line.indent > indent { throw fail("this line is indented past its sequence") }
        return .array(items)
    }

    mutating func mapping(at indent: Int) throws(YAMLError) -> SchemaValue {
        var members: [SchemaMember] = []
        var places: [String: Int] = [:]
        while let line = next(), line.indent == indent {
            if line.text.hasPrefix("\t") { throw fail("a tab in an indent isn't read") }
            guard let (key, rest) = try entry(line.text) else {
                if isItem(line.text) { throw fail("a sequence's item where a mapping's key goes") }
                throw fail("a line that is no key of its mapping")
            }
            at += 1
            let value: SchemaValue
            if rest.isEmpty || rest.hasPrefix("#") {
                // On the lines after: indented past the key, or a sequence at the key's own indent.
                if let after = next(), after.indent == indent, isItem(after.text) {
                    value = try sequence(at: indent)
                } else {
                    value = try node(above: indent)
                }
            } else {
                value = try scalar(rest, line: line, parent: indent)
            }
            if let place = places[key] {
                members[place].value = value
            } else {
                places[key] = members.count
                members.append(SchemaMember(key: key, value: value))
            }
        }
        if let line = next(), line.indent > indent { throw fail("this line is indented past its mapping") }
        return .object(members)
    }

    /// A mapping's entry: its key and what follows its colon; nil for a line that isn't one.
    func entry(_ text: String) throws(YAMLError) -> (key: String, rest: String)? {
        let characters = Array(text)
        guard let first = characters.first else { return nil }
        if first == "?" && (characters.count == 1 || characters[1] == " ") { throw fail("a `?` key isn't read") }
        if first == "\"" || first == "'" {
            // A quoted key: its closing quote, then a colon.
            guard let (key, end) = Self.quoted(characters, from: 0) else { return nil }
            var i = end
            while i < characters.count, characters[i] == " " { i += 1 }
            guard i < characters.count, characters[i] == ":", i + 1 == characters.count || characters[i + 1] == " " else { return nil }
            return (key, String(characters[(i + 1)...]).trimmingCharacters(in: .whitespaces))
        }
        if "[{&*!|>%@`".contains(first) || isItem(text) { return nil }
        // A plain key: up to the first colon followed by a space or the line's end, before any comment.
        var i = 0
        while i < characters.count {
            if characters[i] == "#", i > 0, characters[i - 1] == " " { return nil }
            if characters[i] == ":", i + 1 == characters.count || characters[i + 1] == " " || characters[i + 1] == "\t" {
                let key = String(characters[..<i]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (key, String(characters[(i + 1)...]).trimmingCharacters(in: .whitespaces))
            }
            i += 1
        }
        return nil
    }

    // MARK: Scalars

    /// A value written after a key or a dash (or alone): a block scalar, a flow collection, a quoted string, or a plain scalar,
    /// each of which may go on over the lines after it that are indented past `parent`.
    mutating func scalar(_ text: String, line: YAMLLine, parent: Int) throws(YAMLError) -> SchemaValue {
        guard let first = text.first else { return .null }
        switch first {
        case "&", "*": throw fail("anchors and aliases aren't read", line.number)
        case "!": throw fail("tags aren't read", line.number)
        case "|", ">": return .string(try block(text, line: line, parent: parent))
        case "[", "{": return try flowLine(text, line: line)
        case "\"", "'": return .string(try quotedScalar(text, line: line, parent: parent))
        case "@", "`", "%": throw fail("a plain scalar can't start with \(first)", line.number)
        default: return plainScalar(text, parent: parent)
        }
    }

    /// A plain scalar, its comment cut off, folded with the lines after it indented past `parent`: one space between lines, a
    /// line break for each blank line between them. Read as the core schema reads it.
    mutating func plainScalar(_ text: String, parent: Int) -> SchemaValue {
        var parts = [Self.uncommented(text)]
        var blanks = 0
        var isMultiline = false
        while at < lines.count {
            let line = lines[at]
            if line.text.isEmpty {
                blanks += 1
                at += 1
                continue
            }
            guard line.indent > parent, !line.text.hasPrefix("#"), !isEnd(line) else { break }
            // A line that is a key or an item belongs to the next node.
            if ((try? entry(line.text)) ?? nil) != nil || isItem(line.text) { break }
            parts.append(blanks > 0 ? String(repeating: "\n", count: blanks) : " ")
            parts.append(Self.uncommented(line.text))
            blanks = 0
            isMultiline = true
            at += 1
        }
        // Blank lines after the scalar are the next node's to skip: step back over them.
        if blanks > 0 { at -= blanks }
        let joined = parts.joined()
        return isMultiline ? .string(joined) : Self.resolved(joined)
    }

    /// Text before a comment (` #`).
    static func uncommented(_ text: String) -> String {
        if let range = text.range(of: " #") { return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) }
        if let range = text.range(of: "\t#") { return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return text
    }

    /// A plain scalar as YAML 1.2's core schema reads it: null, a boolean, an integer, a float, else the string.
    static func resolved(_ text: String) -> SchemaValue {
        switch text {
        case "", "~", "null", "Null", "NULL": return .null
        case "true", "True", "TRUE": return .bool(true)
        case "false", "False", "FALSE": return .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": return .number(.infinity)
        case "-.inf", "-.Inf", "-.INF": return .number(-.infinity)
        case ".nan", ".NaN", ".NAN": return .number(.nan)
        default: break
        }
        if text.hasPrefix("0o"), text.count > 2, let value = Int(text.dropFirst(2), radix: 8) { return .number(Double(value)) }
        if text.hasPrefix("0x"), text.count > 2, let value = Int(text.dropFirst(2), radix: 16) { return .number(Double(value)) }
        if isDecimal(text), let value = Double(text) { return .number(value) }
        return .string(text)
    }

    /// Whether text is the core schema's integer or float: `[-+]?[0-9]+`, or `[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?`.
    static func isDecimal(_ text: String) -> Bool {
        var characters = Substring(text)
        if characters.first == "-" || characters.first == "+" { characters = characters.dropFirst() }
        let mantissa = characters.prefix { $0 != "e" && $0 != "E" }
        let exponent = characters.dropFirst(mantissa.count)
        let parts = mantissa.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard !mantissa.isEmpty, parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return false }
        guard parts.contains(where: { !$0.isEmpty }) else { return false }
        // `1.` and `.5` are floats; `.` alone isn't.
        if !exponent.isEmpty {
            var digits = exponent.dropFirst()
            if digits.first == "-" || digits.first == "+" { digits = digits.dropFirst() }
            guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return false }
        }
        return true
    }

    /// A quoted string, which may go on over the lines after it indented past `parent`, folded as YAML folds them (one space a
    /// line break, a line break for each blank line between, a backslash at a line's end joining it to the next with nothing).
    /// What follows its closing quote may only be a comment.
    mutating func quotedScalar(_ text: String, line: YAMLLine, parent: Int) throws(YAMLError) -> String {
        var source = text
        var characters = Array(source)
        while Self.quoted(characters, from: 0) == nil {
            guard at < lines.count else { throw fail("a string left open", line.number) }
            let next = lines[at]
            if !next.text.isEmpty, next.indent <= parent { throw fail("a string left open", line.number) }
            source += "\n" + next.text
            characters = Array(source)
            at += 1
        }
        guard let (value, end) = Self.quoted(characters, from: 0) else { throw fail("a string left open", line.number) }
        let rest = String(characters[end...]).trimmingCharacters(in: .whitespaces)
        guard rest.isEmpty || rest.hasPrefix("#") else { throw fail("words after a string's closing quote", line.number) }
        return value
    }

    /// A quoted string starting at `start` (its quote): its value, its line breaks folded, and where after its closing quote the
    /// text goes on; nil while it's left open.
    static func quoted(_ characters: [Character], from start: Int) -> (String, Int)? {
        let quote = characters[start]
        var value = ""
        var i = start + 1
        // Spaces held back at a line's end, which a line break folds away.
        var pending = ""
        while i < characters.count {
            let c = characters[i]
            if c == "\n" {
                // A line break: blank lines after it are line breaks; else it folds to a space. The next line's indent is gone.
                var breaks = 0
                var j = i
                while j < characters.count, characters[j] == "\n" || characters[j] == " " || characters[j] == "\t" {
                    if characters[j] == "\n" { breaks += 1 }
                    j += 1
                }
                pending = ""
                value += breaks > 1 ? String(repeating: "\n", count: breaks - 1) : " "
                i = j
                continue
            }
            if c == " " || c == "\t" {
                pending.append(c)
                i += 1
                continue
            }
            value += pending
            pending = ""
            if quote == "'" {
                if c == "'" {
                    if i + 1 < characters.count, characters[i + 1] == "'" {
                        value.append("'")
                        i += 2
                        continue
                    }
                    return (value, i + 1)
                }
                value.append(c)
                i += 1
                continue
            }
            if c == "\"" { return (value, i + 1) }
            if c == "\\" {
                guard i + 1 < characters.count else { return nil }
                let e = characters[i + 1]
                i += 2
                switch e {
                case "n": value.append("\n")
                case "t", "\t": value.append("\t")
                case "r": value.append("\r")
                case "0": value.append("\0")
                case "a": value.append("\u{07}")
                case "b": value.append("\u{08}")
                case "e": value.append("\u{1B}")
                case "f": value.append("\u{0C}")
                case "v": value.append("\u{0B}")
                case " ": value.append(" ")
                case "/": value.append("/")
                case "\\": value.append("\\")
                case "\"": value.append("\"")
                case "N": value.append("\u{85}")
                case "_": value.append("\u{A0}")
                case "L": value.append("\u{2028}")
                case "P": value.append("\u{2029}")
                case "x", "u", "U":
                    let count = e == "x" ? 2 : e == "u" ? 4 : 8
                    guard i + count <= characters.count, let code = UInt32(String(characters[i..<(i + count)]), radix: 16),
                          let scalar = Unicode.Scalar(code) else { return nil }
                    value.unicodeScalars.append(scalar)
                    i += count
                case "\n":
                    // An escaped line break: the lines join with nothing, the next one's indent gone.
                    while i < characters.count, characters[i] == " " || characters[i] == "\t" { i += 1 }
                default:
                    value.append("\\")
                    value.append(e)
                }
                continue
            }
            value.append(c)
            i += 1
        }
        return nil
    }

    /// A block scalar, `|` (literal) or `>` (folded), with its chomping (`-` strips the last line breaks, `+` keeps them all, none
    /// keeps one) and an indentation digit: its lines are those after it indented past `parent` (or blank), their indent the first
    /// one's, or the digit's past `parent`.
    mutating func block(_ header: String, line: YAMLLine, parent: Int) throws(YAMLError) -> String {
        let literal = header.first == "|"
        var chomp: Character = " "
        var explicit: Int?
        for c in Self.uncommented(String(header.dropFirst())) {
            if c == "-" || c == "+", chomp == " " {
                chomp = c
            } else if let digit = c.wholeNumberValue, digit > 0, explicit == nil {
                explicit = digit
            } else if c != " " {
                throw fail("a block scalar's header isn't read", line.number)
            }
        }
        var content: [String] = []
        var indent = explicit.map { max(parent, 0) + $0 }
        while at < lines.count {
            let rawLine = lines[at].number - 1 < raw.count ? raw[lines[at].number - 1] : ""
            let spaces = rawLine.prefix { $0 == " " }.count
            let isBlank = rawLine.trimmingCharacters(in: .whitespaces).isEmpty
            if isBlank {
                content.append("")
                at += 1
                continue
            }
            if indent == nil {
                guard spaces > parent else { break }
                indent = spaces
            }
            guard let indent, spaces >= indent else { break }
            if isEnd(lines[at]) { break }
            content.append(String(rawLine.dropFirst(indent)))
            at += 1
        }
        // Trailing blank lines are the chomping's; an indent kept on one says nothing.
        var trailing = 0
        while let last = content.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            content.removeLast()
            trailing += 1
        }
        var text = literal ? content.joined(separator: "\n") : Self.folded(content)
        switch chomp {
        case "-": break
        case "+": if !content.isEmpty || trailing > 0 { text += String(repeating: "\n", count: (content.isEmpty ? 0 : 1) + trailing) }
        default: if !content.isEmpty { text += "\n" }
        }
        return text
    }

    /// A folded block's lines joined: a line break between two lines of text is a space, each blank line between them a line
    /// break, and a line indented past the rest (or next to one) keeps its line breaks.
    static func folded(_ lines: [String]) -> String {
        func isMore(_ line: String) -> Bool { line.first == " " || line.first == "\t" }
        var out = ""
        var lastText: String?
        for (index, line) in lines.enumerated() {
            if index == 0 {
                out = line
                if !line.isEmpty { lastText = line }
                continue
            }
            if line.isEmpty {
                out += "\n"
                continue
            }
            let previous = lines[index - 1]
            if previous.isEmpty {
                // After blank lines: the break before them was folded away, unless it followed or leads to a line indented past the rest.
                if let lastText, isMore(lastText) || isMore(line) { out += "\n" }
                out += line
            } else if isMore(previous) || isMore(line) {
                out += "\n" + line
            } else {
                out += " " + line
            }
            lastText = line
        }
        return out
    }

    // MARK: Flow collections

    /// A flow collection on one line, `[…]` or `{…}`; what follows it may only be a comment. One that runs over several lines
    /// isn't read.
    mutating func flowLine(_ text: String, line: YAMLLine) throws(YAMLError) -> SchemaValue {
        var flow = YAMLFlow(Array(text), line: line.number)
        let value = try flow.value(depth: 0)
        flow.skipSpaces()
        let rest = String(flow.characters[flow.at...])
        guard rest.isEmpty || rest.hasPrefix("#") else { throw fail("words after a flow collection", line.number) }
        return value
    }
}

/// A flow collection's reader: `[a, "b", {c: 1}]` on one line.
private struct YAMLFlow {
    let characters: [Character]
    let line: Int
    var at = 0

    init(_ characters: [Character], line: Int) {
        self.characters = characters
        self.line = line
    }

    func fail(_ message: String) -> YAMLError { YAMLError(message: message, line: line) }

    mutating func skipSpaces() {
        while at < characters.count, characters[at] == " " || characters[at] == "\t" { at += 1 }
    }

    mutating func value(depth: Int) throws(YAMLError) -> SchemaValue {
        guard depth < YAMLReader.maxDepth else { throw fail("nested too deep") }
        skipSpaces()
        guard at < characters.count else { throw fail("a flow collection left open: one over several lines isn't read") }
        switch characters[at] {
        case "[": return try sequence(depth: depth)
        case "{": return try mapping(depth: depth)
        case "\"", "'": return .string(try quotedString())
        case "&", "*": throw fail("anchors and aliases aren't read")
        case "!": throw fail("tags aren't read")
        default: return YAMLParser.resolved(plain(inMapping: false))
        }
    }

    mutating func sequence(depth: Int) throws(YAMLError) -> SchemaValue {
        at += 1
        var items: [SchemaValue] = []
        while true {
            skipSpaces()
            guard at < characters.count else { throw fail("a flow sequence left open: one over several lines isn't read") }
            if characters[at] == "]" {
                at += 1
                return .array(items)
            }
            items.append(try value(depth: depth + 1))
            skipSpaces()
            guard at < characters.count else { throw fail("a flow sequence left open: one over several lines isn't read") }
            if characters[at] == "," {
                at += 1
            } else if characters[at] != "]" {
                throw fail("a flow sequence's items are separated by commas")
            }
        }
    }

    mutating func mapping(depth: Int) throws(YAMLError) -> SchemaValue {
        at += 1
        var members: [SchemaMember] = []
        var places: [String: Int] = [:]
        while true {
            skipSpaces()
            guard at < characters.count else { throw fail("a flow mapping left open: one over several lines isn't read") }
            if characters[at] == "}" {
                at += 1
                return .object(members)
            }
            let key: String
            if characters[at] == "\"" || characters[at] == "'" {
                key = try quotedString()
            } else {
                key = plain(inMapping: true)
            }
            skipSpaces()
            var value = SchemaValue.null
            if at < characters.count, characters[at] == ":" {
                at += 1
                skipSpaces()
                if at < characters.count, characters[at] != ",", characters[at] != "}" { value = try self.value(depth: depth + 1) }
            }
            if let place = places[key] {
                members[place].value = value
            } else {
                places[key] = members.count
                members.append(SchemaMember(key: key, value: value))
            }
            skipSpaces()
            guard at < characters.count else { throw fail("a flow mapping left open: one over several lines isn't read") }
            if characters[at] == "," {
                at += 1
            } else if characters[at] != "}" {
                throw fail("a flow mapping's entries are separated by commas")
            }
        }
    }

    /// A plain scalar in a flow collection: up to a comma, a closing bracket, or (a key's) a colon and a space.
    mutating func plain(inMapping: Bool) -> String {
        let start = at
        while at < characters.count {
            let c = characters[at]
            if c == "," || c == "]" || c == "}" { break }
            if c == ":", inMapping, at + 1 >= characters.count || [" ", ",", "}"].contains(characters[at + 1]) { break }
            if c == "#", at > start, characters[at - 1] == " " { break }
            at += 1
        }
        return String(characters[start..<at]).trimmingCharacters(in: .whitespaces)
    }

    mutating func quotedString() throws(YAMLError) -> String {
        guard let (value, end) = YAMLParser.quoted(characters, from: at) else { throw fail("a string left open") }
        at = end
        return value
    }
}
