// An order-preserving JSON reader. Foundation's JSONSerialization hands back dictionaries, which lose
// the order properties were written in (the card and the person writing care about it), and it says
// where the text went wrong only as a character offset. This one keeps every object's members in
// order, where each value and key is in the text (for errors' line and column, and for small edits
// that leave the rest of the text as it was), and never crashes: whatever the text, it returns a
// value or an error.

/// A JSON value read from text, and where it is: `range` is in UTF-8 offsets into that text, from
/// its first character to just past its last (a string's quotes included).
public struct JSONNode: Equatable, Sendable {
    public enum Value: Equatable, Sendable {
        /// Members in the order they were written, duplicates included.
        case object([JSONMember])
        case array([JSONNode])
        case string(String)
        /// The number as written (`1.50`, `-0`, `1e400`), which is valid JSON.
        case number(String)
        case bool(Bool)
        case null
    }

    public var value: Value
    public var range: Range<Int>

    public init(_ value: Value, range: Range<Int>) {
        self.value = value
        self.range = range
    }

    /// The value of the member called `key`, if this is an object with one. With two, the last:
    /// what JavaScript's `JSON.parse` keeps.
    public subscript(key: String) -> JSONNode? {
        guard case .object(let members) = value else { return nil }
        return members.last { $0.key == key }?.value
    }

    public var members: [JSONMember]? {
        if case .object(let members) = value { return members }
        return nil
    }

    public var elements: [JSONNode]? {
        if case .array(let elements) = value { return elements }
        return nil
    }

    public var string: String? {
        if case .string(let string) = value { return string }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let bool) = value { return bool }
        return nil
    }

    public var number: Double? {
        if case .number(let literal) = value { return Double(literal) }
        return nil
    }

    public var isObject: Bool { members != nil }

    /// One short line for showing a value: a string bare, a number as written, `true`, `null`; an
    /// object `{…}` and an array `[…]`.
    public var brief: String {
        switch value {
        case .string(let string): string
        case .number(let literal): literal
        case .bool(let bool): bool ? "true" : "false"
        case .null: "null"
        case .object: "{…}"
        case .array: "[…]"
        }
    }
}

/// One member of an object: its key, where the key is (its quotes included), and its value.
public struct JSONMember: Equatable, Sendable {
    public var key: String
    public var keyRange: Range<Int>
    public var value: JSONNode

    public init(key: String, keyRange: Range<Int>, value: JSONNode) {
        self.key = key
        self.keyRange = keyRange
        self.value = value
    }
}

/// Why a text isn't JSON, and where: the UTF-8 offset, and the line and column a person counts (both
/// from 1; a column counts characters, so "é" is one).
public struct JSONSyntaxError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var offset: Int
    public var line: Int
    public var column: Int
    /// The root object's members read whole before the error, in order (none if the root isn't an
    /// object): what can still be said of a half-typed document, its name, say.
    public var rootMembers: [JSONMember]

    public init(message: String, offset: Int, line: Int, column: Int, rootMembers: [JSONMember] = []) {
        self.message = message
        self.offset = offset
        self.line = line
        self.column = column
        self.rootMembers = rootMembers
    }

    /// "Line 6, column 35: Expected a property name".
    public var description: String { "Line \(line), column \(column): \(message)" }
}

/// A token of JSON text, and where it is (UTF-8 offsets).
public struct JSONToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case openBrace, closeBrace, openBracket, closeBracket, colon, comma
        /// Its quotes included. One that runs to the end of its line without closing is `invalid`.
        case string
        /// A run of the characters numbers are made of; the reader checks its form.
        case number
        /// `true`, `false` or `null`.
        case literal
        /// Anything else: a stray character, a word that isn't a literal, a string left open.
        case invalid
    }

    public var kind: Kind
    public var range: Range<Int>

    public init(_ kind: Kind, _ range: Range<Int>) {
        self.kind = kind
        self.range = range
    }
}

public enum JSONReader {
    /// Arrays and objects nest at most this deep; deeper is an error, so no text can exhaust the
    /// stack.
    public static let maxDepth = 256

    /// Reads `text` as one JSON value (whitespace around it allowed), or says why it isn't one.
    public static func read(_ text: String) throws(JSONSyntaxError) -> JSONNode {
        var parser = Parser(Array(text.utf8))
        return try parser.document()
    }

    /// Every token in `text`, in order, whether or not it reads as JSON: for coloring it, say.
    public static func tokens(in text: String) -> [JSONToken] {
        var scanner = Scanner(Array(text.utf8))
        var tokens: [JSONToken] = []
        while let token = scanner.next() { tokens.append(token) }
        return tokens
    }

    /// The tokens scanned from offset `start` in `bytes` that start before `end`: part of a text
    /// scanned again from somewhere other than where its tokens began (`JSONCaret`).
    static func tokens(in bytes: [UInt8], from start: Int, before end: Int) -> [JSONToken] {
        var scanner = Scanner(bytes)
        scanner.i = start
        var tokens: [JSONToken] = []
        while let token = scanner.next(), token.range.lowerBound < end { tokens.append(token) }
        return tokens
    }

    /// Whether `range` of `bytes` is a number as JSON writes one, the whole range:
    /// `-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?`.
    static func isNumber(_ bytes: [UInt8], _ range: Range<Int>) -> Bool {
        var k = range.lowerBound
        let end = range.upperBound
        // Each part in turn: its sign, its whole digits, a fraction, an exponent.
        if k < end, bytes[k] == UInt8(ascii: "-") { k += 1 }
        var start = k
        while k < end, bytes[k].isDigit { k += 1 }
        if k == start || (bytes[start] == UInt8(ascii: "0") && k - start > 1) { return false }
        if k < end, bytes[k] == UInt8(ascii: ".") {
            k += 1
            start = k
            while k < end, bytes[k].isDigit { k += 1 }
            if k == start { return false }
        }
        if k < end, bytes[k] == UInt8(ascii: "e") || bytes[k] == UInt8(ascii: "E") {
            k += 1
            if k < end, bytes[k] == UInt8(ascii: "+") || bytes[k] == UInt8(ascii: "-") { k += 1 }
            start = k
            while k < end, bytes[k].isDigit { k += 1 }
            if k == start { return false }
        }
        return k == end
    }

    /// `string` as a JSON string literal, quotes included: `"`, `\` and control characters escaped,
    /// everything else as it is.
    public static func literal(_ string: String) -> String {
        var out = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case ..<" ":
                let hex = String(scalar.value, radix: 16)
                out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The line and column (from 1; columns in characters) of a UTF-8 offset into `text`.
    public static func position(of offset: Int, in text: String) -> (line: Int, column: Int) {
        position(of: offset, in: Array(text.utf8))
    }

    static func position(of offset: Int, in bytes: [UInt8]) -> (line: Int, column: Int) {
        let end = min(max(0, offset), bytes.count)
        var line = 1, lineStart = 0
        for i in 0..<end where bytes[i] == UInt8(ascii: "\n") {
            line += 1
            lineStart = i + 1
        }
        return (line, String(decoding: bytes[lineStart..<end], as: UTF8.self).count + 1)
    }
}

// MARK: Scanning

private extension UInt8 {
    var isJSONSpace: Bool { self == 0x20 || self == 0x0A || self == 0x0D || self == 0x09 }
    var isDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
    var isWordCharacter: Bool {
        (self >= UInt8(ascii: "a") && self <= UInt8(ascii: "z")) || (self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z"))
            || isDigit || self == UInt8(ascii: "_") || self == UInt8(ascii: "$")
    }
    var isNumberCharacter: Bool {
        isDigit || self == UInt8(ascii: "-") || self == UInt8(ascii: "+") || self == UInt8(ascii: ".")
            || self == UInt8(ascii: "e") || self == UInt8(ascii: "E")
    }
    /// Not a UTF-8 continuation byte: where a character's bytes start.
    var startsScalar: Bool { self & 0xC0 != 0x80 }
}

private struct Scanner {
    let bytes: [UInt8]
    var i = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }

    mutating func next() -> JSONToken? {
        while i < bytes.count, bytes[i].isJSONSpace { i += 1 }
        guard i < bytes.count else { return nil }
        let start = i, byte = bytes[i]
        func token(_ kind: JSONToken.Kind) -> JSONToken { JSONToken(kind, start..<i) }
        i += 1
        switch byte {
        case UInt8(ascii: "{"): return token(.openBrace)
        case UInt8(ascii: "}"): return token(.closeBrace)
        case UInt8(ascii: "["): return token(.openBracket)
        case UInt8(ascii: "]"): return token(.closeBracket)
        case UInt8(ascii: ":"): return token(.colon)
        case UInt8(ascii: ","): return token(.comma)
        case UInt8(ascii: "\""):
            // To the closing quote; a line break first leaves it open (JSON strings hold none).
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: "\""):
                    i += 1
                    return token(.string)
                case UInt8(ascii: "\\"):
                    i = min(i + 2, bytes.count)
                case UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                    return token(.invalid)
                default:
                    i += 1
                }
            }
            return token(.invalid)
        case let b where b == UInt8(ascii: "-") || b.isDigit:
            while i < bytes.count, bytes[i].isNumberCharacter { i += 1 }
            return token(.number)
        case let b where b.isWordCharacter:
            while i < bytes.count, bytes[i].isWordCharacter { i += 1 }
            let word = bytes[start..<i]
            return token(word.elementsEqual("true".utf8) || word.elementsEqual("false".utf8) || word.elementsEqual("null".utf8)
                         ? .literal : .invalid)
        default:
            while i < bytes.count, !bytes[i].startsScalar { i += 1 }
            return token(.invalid)
        }
    }
}

// MARK: Parsing

private struct Parser {
    var scanner: Scanner
    var token: JSONToken?
    var depth = 0
    var rootMembers: [JSONMember] = []

    init(_ bytes: [UInt8]) {
        scanner = Scanner(bytes)
        token = scanner.next()
    }

    var bytes: [UInt8] { scanner.bytes }

    mutating func advance() { token = scanner.next() }

    func error(_ message: String, at offset: Int) -> JSONSyntaxError {
        let (line, column) = JSONReader.position(of: offset, in: bytes)
        return JSONSyntaxError(message: message, offset: offset, line: line, column: column, rootMembers: rootMembers)
    }

    /// An error at the current token, or at the end.
    func error(_ message: String) -> JSONSyntaxError {
        error(message, at: token?.range.lowerBound ?? bytes.count)
    }

    func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

    mutating func document() throws(JSONSyntaxError) -> JSONNode {
        let root = try value()
        if token != nil { throw error("Unexpected text after the end") }
        return root
    }

    mutating func value() throws(JSONSyntaxError) -> JSONNode {
        guard let token else { throw error("Expected a value") }
        switch token.kind {
        case .openBrace: return try object(from: token)
        case .openBracket: return try array(from: token)
        case .string:
            advance()
            return JSONNode(.string(try string(token)), range: token.range)
        case .number:
            guard JSONReader.isNumber(bytes, token.range) else { throw error("Invalid number", at: token.range.lowerBound) }
            advance()
            return JSONNode(.number(text(token.range)), range: token.range)
        case .literal:
            advance()
            let word = text(token.range)
            return JSONNode(word == "null" ? .null : .bool(word == "true"), range: token.range)
        case .invalid:
            throw unexpected(token)
        case .closeBrace, .closeBracket, .colon, .comma:
            throw error("Expected a value")
        }
    }

    func unexpected(_ token: JSONToken) -> JSONSyntaxError {
        if bytes[token.range.lowerBound] == UInt8(ascii: "\"") { return error("Unterminated string", at: token.range.lowerBound) }
        let word = text(token.range)
        return error("Unexpected “\(word.count > 20 ? String(word.prefix(20)) + "…" : word)”", at: token.range.lowerBound)
    }

    mutating func nest(_ open: JSONToken) throws(JSONSyntaxError) {
        depth += 1
        if depth > JSONReader.maxDepth { throw error("Nested more than \(JSONReader.maxDepth) deep", at: open.range.lowerBound) }
    }

    mutating func object(from open: JSONToken) throws(JSONSyntaxError) -> JSONNode {
        try nest(open)
        defer { depth -= 1 }
        let isRoot = depth == 1
        advance()
        var members: [JSONMember] = []
        if token?.kind == .closeBrace {
            let end = token!.range.upperBound
            advance()
            return JSONNode(.object(members), range: open.range.lowerBound..<end)
        }
        while true {
            guard let key = token, key.kind == .string else {
                if let token, token.kind == .invalid, bytes[token.range.lowerBound] == UInt8(ascii: "\"") { throw unexpected(token) }
                throw error("Expected a property name")
            }
            let name = try string(key)
            advance()
            guard token?.kind == .colon else { throw error("Expected “:”") }
            advance()
            let member = JSONMember(key: name, keyRange: key.range, value: try value())
            members.append(member)
            if isRoot { rootMembers.append(member) }
            guard let next = token else { throw error("Expected “,” or “}”") }
            advance()
            switch next.kind {
            case .comma: continue
            case .closeBrace: return JSONNode(.object(members), range: open.range.lowerBound..<next.range.upperBound)
            default: throw error("Expected “,” or “}”", at: next.range.lowerBound)
            }
        }
    }

    mutating func array(from open: JSONToken) throws(JSONSyntaxError) -> JSONNode {
        try nest(open)
        defer { depth -= 1 }
        advance()
        var elements: [JSONNode] = []
        if token?.kind == .closeBracket {
            let end = token!.range.upperBound
            advance()
            return JSONNode(.array(elements), range: open.range.lowerBound..<end)
        }
        while true {
            elements.append(try value())
            guard let next = token else { throw error("Expected “,” or “]”") }
            advance()
            switch next.kind {
            case .comma: continue
            case .closeBracket: return JSONNode(.array(elements), range: open.range.lowerBound..<next.range.upperBound)
            default: throw error("Expected “,” or “]”", at: next.range.lowerBound)
            }
        }
    }

    /// A string token's contents, its escapes decoded.
    func string(_ token: JSONToken) throws(JSONSyntaxError) -> String {
        let start = token.range.lowerBound + 1, end = token.range.upperBound - 1
        var out: [UInt8] = []
        var i = start, plain = start
        func hex(_ at: Int) -> UInt32? {
            guard at + 4 <= end else { return nil }
            var value: UInt32 = 0
            for b in bytes[at..<at + 4] {
                guard let digit = Character(UnicodeScalar(b)).hexDigitValue else { return nil }
                value = value * 16 + UInt32(digit)
            }
            return value
        }
        while i < end {
            let b = bytes[i]
            if b < 0x20 { throw error("Control character in a string", at: i) }
            guard b == UInt8(ascii: "\\") else { i += 1; continue }
            out.append(contentsOf: bytes[plain..<i])
            guard i + 1 < end else { throw error("Invalid escape", at: i) }
            let escaped = bytes[i + 1]
            var scalar: UnicodeScalar?
            var length = 2
            switch escaped {
            case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escaped)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "u"):
                guard let unit = hex(i + 2) else { throw error("Invalid escape", at: i) }
                length = 6
                if (0xD800..<0xDC00).contains(unit), i + 12 <= end, bytes[i + 6] == UInt8(ascii: "\\"), bytes[i + 7] == UInt8(ascii: "u"),
                   let low = hex(i + 8), (0xDC00..<0xE000).contains(low) {
                    scalar = UnicodeScalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                    length = 12
                } else {
                    scalar = UnicodeScalar(unit) ?? "\u{FFFD}"   // a lone surrogate
                }
            default:
                throw error("Invalid escape", at: i)
            }
            if let scalar { out.append(contentsOf: Array(String(scalar).utf8)) }
            i += length
            plain = i
        }
        if plain == start { return text(start..<end) }
        out.append(contentsOf: bytes[plain..<end])
        return String(decoding: out, as: UTF8.self)
    }
}
