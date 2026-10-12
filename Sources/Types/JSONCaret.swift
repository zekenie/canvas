import Canvas
import Foundation

// Where a caret is in JSON text that may be half-typed, for completing it there: which object or
// array it's in, whether a key or a value goes where it is, what's typed of it so far and what a
// pick replaces, and what's around it. A text being typed is seldom JSON, so it's read leniently,
// as jsonc-parser reads one (Microsoft's reader behind VS Code's JSON editing, MIT): a missing comma
// or colon is skipped past, a stray token is skipped, and a container left open closes at the end.
// Three rules of its own read a text as it's usually being typed. A string at the caret that runs on
// past the word typed there, left open (to its line's end) or closed by what's surely the next
// string's opening quote, ends after that word, and the rest of its line reads as it would once the
// string's closed there. A closed string followed by a `:` where a value goes is the next member's
// key, the value not typed yet. And in a text whose brackets don't pair up, indentation says where
// a container left open ends, so it doesn't take the members after it that its parent's lines hold:
// a closing bracket at the start of a line closes the container of its kind opened on a line
// indented no further, and a line indented no further than a container's opening line, while its
// content's lines were further in, is its parent's. Any text reads as some tree, in one pass over
// its tokens.

/// Where a caret is in JSON text that may be half-typed, and what's around it: what completing
/// there needs to know. Offsets and ranges are UTF-8 offsets into the text.
public struct JSONCaret: Equatable, Sendable {
    /// What goes where the caret is.
    public enum Position: Equatable, Sendable {
        /// A member's key, in the object `path` leads to: none typed yet, or one being typed.
        case key
        /// The value of the member with this key, in the object `path` leads to.
        case value(of: String)
        /// The element at this index of the array `path` leads to. Every value written before it
        /// counts, one that doesn't read (a word that isn't JSON) too.
        case element(Int)
    }

    /// The steps from the root to the object or array the caret is in: a member's key, an
    /// element's index.
    public var path: [JSONPathComponent]
    public var position: Position
    /// What a pick replaces, which always holds the caret. Where nothing is typed, the caret alone
    /// (an empty range). A string whose closing quote is where a key or a value ends (a `,`, `:`,
    /// `}` or `]` follows it, past spaces, or its line ends), whole, the caret after its closing
    /// quote too. Any other string, its opening quote to the caret, then the characters after the
    /// caret that could be part of one word (not space, a quote, a backslash or JSON's punctuation),
    /// then the closing quote if it comes right after them: never more, since a quote left open on a
    /// line, or typed before a string, pairs with the next string's opening quote. A word (`tru`,
    /// `true`, a key without quotes) whole.
    public var replace: Range<Int>
    /// What's typed from where `replace` starts, a string's opening quote left out, to the caret
    /// (a closed string's closing quote left out too): what a pick is matched against.
    public var query: String
    /// Whether what's being typed is a string (it opened with a quote), not a word.
    public var isQuoted: Bool
    /// At a key's place, typed or not: a `:` follows, so a pick renames the key, or names one, and
    /// writes no value.
    public var hasColon: Bool
    /// Where a comma is missing before the caret: just after the value before it, which no comma
    /// follows. A pick that writes a member or an element puts the comma there, keeping what's
    /// between (`text[commaBefore..<replace.lowerBound]`) as it was.
    public var commaBefore: Int?
    /// A key or a value follows what's typed, or the caret, in the same object or array, with no
    /// comma between: a pick that writes a member or an element ends with one.
    public var needsCommaAfter: Bool
    /// The other members of the object the caret is in (at a key or a value), as read, in order,
    /// on both sides of the caret; the member being typed (its key or its value) is left out. Empty
    /// at an element.
    public var siblings: [JSONMember]
    /// At an element: the array's other elements, as read, in order; the one being typed left out.
    /// Empty at a key or a value.
    public var elements: [JSONNode]
    /// The objects and arrays from the root to the one the caret is in, as read: the root first,
    /// then each one `path`'s steps lead to. What's being typed is in them where it reads (a closed
    /// string, say).
    public var containers: [JSONNode]

    /// The whole text as read: for what's defined elsewhere in it (`$defs`).
    public var root: JSONNode { containers[0] }
    /// The object or array the caret is in, as read.
    public var container: JSONNode { containers[containers.count - 1] }

    public init(path: [JSONPathComponent], position: Position, replace: Range<Int>, query: String, isQuoted: Bool, hasColon: Bool,
                commaBefore: Int?, needsCommaAfter: Bool, siblings: [JSONMember], elements: [JSONNode], containers: [JSONNode]) {
        self.path = path
        self.position = position
        self.replace = replace
        self.query = query
        self.isQuoted = isQuoted
        self.hasColon = hasColon
        self.commaBefore = commaBefore
        self.needsCommaAfter = needsCommaAfter
        self.siblings = siblings
        self.elements = elements
        self.containers = containers
    }

    /// Where the caret at `offset` (UTF-8) is in `text`. Nil where no completion makes sense:
    /// before or after the root, which must be an object or an array (an empty text has none);
    /// inside or at the end of a number; after a key with no colon, or before a member's value
    /// (put the caret on the value); in a container nested deeper than `JSONReader.maxDepth`, or
    /// in one that's no member or element (`{ {…} }`).
    public static func at(_ offset: Int, in text: String) -> JSONCaret? {
        let bytes = Array(text.utf8)
        guard offset >= 0, offset <= bytes.count else { return nil }
        var reader = CaretReader(bytes: bytes, tokens: typed(JSONReader.tokens(in: text), bytes, caret: offset), caret: offset)
        return reader.read()
    }

    /// `tokens` as they read with what's typed at the caret: where the caret is in a string whose
    /// token runs on past the word typed there (left open, to its line's end; or closed by a quote
    /// that a word or another quote follows, so surely the next string's opening one), that string
    /// ends after the word (and the quote right after it, if there is one), and the rest of its line
    /// is scanned again from there. A string closed where a key or a value ends is whole as written.
    private static func typed(_ tokens: [JSONToken], _ bytes: [UInt8], caret: Int) -> [JSONToken] {
        // The token the caret is in, or at the end of: the first that ends at or after it.
        var low = 0, high = tokens.count
        while low < high {
            let middle = (low + high) / 2
            if tokens[middle].range.upperBound < caret { low = middle + 1 } else { high = middle }
        }
        guard low < tokens.count else { return tokens }
        let range = tokens[low].range
        guard range.lowerBound < caret, bytes[range.lowerBound] == UInt8(ascii: "\"") else { return tokens }
        if tokens[low].kind == .string {
            var next = range.upperBound
            while next < bytes.count, bytes[next] == 0x20 || bytes[next] == 0x09 { next += 1 }   // space, tab
            guard next < bytes.count else { return tokens }
            switch bytes[next] {
            case UInt8(ascii: ","), UInt8(ascii: ":"), UInt8(ascii: "}"), UInt8(ascii: "]"), 0x0A, 0x0D: return tokens
            default: break
            }
        }
        var end = caret
        while end < range.upperBound, bytes[end].isWordByte { end += 1 }
        if end < range.upperBound, bytes[end] == UInt8(ascii: "\"") { end += 1 }
        guard end < range.upperBound else { return tokens }
        // Tokens never span a line break, so past the line's end they're as they were.
        var lineEnd = end
        while lineEnd < bytes.count, bytes[lineEnd] != 0x0A, bytes[lineEnd] != 0x0D { lineEnd += 1 }
        let after = tokens[(low + 1)...].firstIndex { $0.range.lowerBound >= lineEnd } ?? tokens.count
        return Array(tokens[..<low]) + [JSONToken(.invalid, range.lowerBound..<end)]
            + JSONReader.tokens(in: bytes, from: end, before: lineEnd) + tokens[after...]
    }
}

// MARK: Reading

/// A token as the reader takes it.
private enum Piece: Equatable {
    case open(isObject: Bool), close(isObject: Bool), colon, comma
    /// A string, closed or left open (it runs to its line's end).
    case string(closed: Bool)
    /// A run of word characters: `true`, `false`, `null`, or one that isn't JSON (a key without
    /// quotes, a literal half typed).
    case word
    case number
    /// A character JSON has no use for.
    case stray

    /// Whether a key or a value starts with it.
    var startsValue: Bool {
        switch self {
        case .open, .string, .word, .number: true
        case .close, .colon, .comma, .stray: false
        }
    }
}

/// An object or array being read.
private struct Opened {
    var isObject: Bool
    /// The indentation of the line it opens on, in a text whose brackets don't pair up.
    var indent: Int
}

/// The caret, found in the container being read: what goes there, and what the rest of the
/// container says of it once it's read.
private struct Here {
    var position: JSONCaret.Position
    var replace: Range<Int>
    var query: String
    var isQuoted: Bool
    /// At a key's place, typed or not, which may have a colon after it.
    var isKey: Bool
    var commaBefore: Int?
    /// The token after what's typed, or after the caret.
    var next: Int
}

private enum Search {
    case searching
    /// Found, in the container being read or one inside it.
    case found
    /// Somewhere no completion goes.
    case lost
}

/// The text being read and the caret: its bytes, its tokens, and each token as the reader takes
/// it. A class, so the reader holds it as one reference (a debug build copies a struct whole to
/// call a method on it).
private final class Source {
    let bytes: [UInt8]
    let tokens: [JSONToken]
    let pieces: [Piece]
    /// Whether the text's brackets don't pair up (a container is left open, or closed by the other
    /// kind of bracket): only then does indentation say where a container ends.
    let readsIndentation: Bool
    /// Where each backslash is, in order: a string holding none (most do) is its bytes as they are.
    let escapes: [Int]
    let caret: Int

    init(bytes: [UInt8], tokens: [JSONToken], caret: Int) {
        self.bytes = bytes
        self.tokens = tokens
        self.caret = caret
        // Each token's piece, and whether every closing bracket closes the last one opened and every
        // one opened closes, in one pass (a debug build pays for each step over an array).
        var pieces: [Piece] = []
        pieces.reserveCapacity(tokens.count)
        var opened: [Bool] = [], pairs = true
        var k = 0
        while k < tokens.count {
            let token = tokens[k]
            k += 1
            switch token.kind {
            case .openBrace, .openBracket:
                let isObject = token.kind == .openBrace
                pieces.append(.open(isObject: isObject))
                opened.append(isObject)
            case .closeBrace, .closeBracket:
                let isObject = token.kind == .closeBrace
                pieces.append(.close(isObject: isObject))
                if pairs, opened.popLast() != isObject { pairs = false }
            case .colon: pieces.append(.colon)
            case .comma: pieces.append(.comma)
            case .string: pieces.append(.string(closed: true))
            case .number: pieces.append(.number)
            case .literal: pieces.append(.word)
            case .invalid:
                let first = bytes[token.range.lowerBound]
                pieces.append(first == UInt8(ascii: "\"") ? .string(closed: false) : first.startsWord ? .word : .stray)
            }
        }
        self.pieces = pieces
        readsIndentation = !pairs || !opened.isEmpty
        escapes = bytes.withUnsafeBufferPointer { buffer in
            var escapes: [Int] = []
            guard let base = buffer.baseAddress else { return escapes }
            var from = 0
            while from < buffer.count, let found = memchr(base + from, Int32(UInt8(ascii: "\\")), buffer.count - from) {
                let offset = UnsafeRawPointer(found) - UnsafeRawPointer(base)
                escapes.append(offset)
                from = offset + 1
            }
            return escapes
        }
    }

    /// How far in token `k`'s line is indented (in bytes of space and tab), if `k` is the first
    /// token on it; nil if it isn't. Only space comes between tokens, so what's before the
    /// indentation is a line break, or another token.
    func indent(ofFirst k: Int) -> Int? {
        let start = tokens[k].range.lowerBound
        var p = start
        while p > 0, bytes[p - 1] == 0x20 || bytes[p - 1] == 0x09 { p -= 1 }   // space, tab
        return p == 0 || bytes[p - 1] == 0x0A || bytes[p - 1] == 0x0D ? start - p : nil   // a line break
    }

    /// Whether the caret, while it's being searched for, is at token `k`, being typed: inside it, or
    /// at its end. (At its start, the caret is before it.)
    func holdsCaret(_ k: Int, _ search: Search) -> Bool {
        guard case .searching = search else { return false }
        let range = tokens[k].range
        return range.lowerBound < caret && caret <= range.upperBound
    }

    /// The caret at string or word token `k`, being typed there: the token whole, a string ending
    /// where what's typed does already (`JSONCaret.typed`).
    func partial(_ k: Int, _ position: JSONCaret.Position, commaBefore: Int?) -> Here {
        let range = tokens[k].range
        let query: String, isQuoted: Bool
        switch pieces[k] {
        case .string(let closed):
            // After a closed string's closing quote, what's typed is all of it.
            query = text(range.lowerBound + 1..<(closed && caret == range.upperBound ? caret - 1 : caret))
            isQuoted = true
        default:
            query = text(range.lowerBound..<caret)
            isQuoted = false
        }
        return Here(position: position, replace: range, query: query, isQuoted: isQuoted, isKey: position == .key, commaBefore: commaBefore,
                    next: k + 1)
    }

    /// The caret between tokens, where nothing's typed.
    func empty(_ position: JSONCaret.Position, commaBefore: Int?, next: Int) -> Here {
        Here(position: position, replace: caret..<caret, query: "", isQuoted: false, isKey: position == .key, commaBefore: commaBefore,
             next: next)
    }

    func text(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }

    /// A string or word token as a key: a string's contents (as far as it goes, if it's left
    /// open), its escapes read where they're valid.
    func name(_ k: Int) -> String {
        let range = tokens[k].range
        guard case .string(let closed) = pieces[k] else { return text(range) }
        let inner = range.lowerBound + 1..<(closed ? range.upperBound - 1 : range.upperBound)
        let raw = text(inner)
        guard hasEscape(in: inner) else { return raw }
        return (try? JSONReader.read("\"" + raw + "\""))?.string ?? raw
    }

    /// Whether a backslash is in `range`.
    func hasEscape(in range: Range<Int>) -> Bool {
        guard !escapes.isEmpty else { return false }
        var low = 0, high = escapes.count
        while low < high {
            let middle = (low + high) / 2
            if escapes[middle] < range.lowerBound { low = middle + 1 } else { high = middle }
        }
        return low < escapes.count && escapes[low] < range.upperBound
    }

    /// Token `k` as a value, if it reads as one: a string (one left open, as far as it goes), a
    /// number as JSON writes one, `true`, `false`, `null`.
    func value(_ k: Int) -> JSONNode? {
        let range = tokens[k].range
        switch pieces[k] {
        case .string:
            return JSONNode(.string(name(k)), range: range)
        case .number:
            return JSONReader.isNumber(bytes, range) ? JSONNode(.number(text(range)), range: range) : nil
        case .word:
            switch text(range) {
            case "true": return JSONNode(.bool(true), range: range)
            case "false": return JSONNode(.bool(false), range: range)
            case "null": return JSONNode(.null, range: range)
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Whether token `k`, where a value goes, is the next member's key instead: a closed string
    /// followed by a colon.
    func isKeyAhead(_ k: Int) -> Bool {
        guard case .string(closed: true) = pieces[k], k + 1 < pieces.count, case .colon = pieces[k + 1] else { return false }
        return true
    }

    /// Whether a line break comes between the end of token `a` and the start of token `b`.
    func breaksLine(from a: Int, to b: Int) -> Bool {
        var k = tokens[a].range.upperBound
        let end = tokens[b].range.lowerBound
        while k < end, bytes[k] != UInt8(ascii: "\n") { k += 1 }
        return k < end
    }

    enum Ending { case closes, endsBefore }

    /// Whether the innermost of `open` ends at closing bracket `k`: `closes` if it's its own;
    /// `endsBefore` if it's for one around it (in a text whose brackets don't pair up, a bracket
    /// that starts a line closes the one of its kind opened on a line indented no further); nil for
    /// one no container is open for, which it passes over.
    func ending(atClosing k: Int, isObject: Bool, in open: [Opened]) -> Ending? {
        var target = open.lastIndex { $0.isObject == isObject }
        if readsIndentation, let line = indent(ofFirst: k),
           let outdented = open.lastIndex(where: { $0.isObject == isObject && $0.indent <= line }) {
            target = outdented
        }
        guard let target else { return nil }
        return target == open.count - 1 ? .closes : .endsBefore
    }
}

/// What's been read of an object or an array: the reader reads one token at a time into it.
private protocol ContainerReading {
    static var isObject: Bool { get }
    init()
    /// The caret between tokens, just before token `k` (`endsHere`: the container ends there).
    func gap(before k: Int, endsHere: Bool, in source: Source) -> Here?
    /// Reads the reader's current token, and anything it opens.
    mutating func read(_ reader: inout CaretReader, here: inout Here?, depth: Int)
    func node(_ range: Range<Int>) -> JSONNode
    /// The members, or elements, beside the one being typed.
    var others: (siblings: [JSONMember], elements: [JSONNode]) { get }
}

private struct CaretReader {
    let source: Source
    /// The next token.
    var i = 0
    /// The end of the last token read. A caret before it that no container has claimed is inside
    /// something no completion goes in.
    var readTo = 0
    var search = Search.searching
    /// The containers being read, the innermost last.
    var open: [Opened] = []
    /// The last token whose line's indentation has been read, and that indentation: a text is read
    /// forward, so each token is looked at once to find where its line starts.
    var lineRead = (token: -1, indent: 0)
    /// Built as the containers holding the caret end, innermost first: its path and containers
    /// are turned around once the root ends.
    var found = JSONCaret(path: [], position: .key, replace: 0..<0, query: "", isQuoted: false, hasColon: false,
                          commaBefore: nil, needsCommaAfter: false, siblings: [], elements: [], containers: [])

    init(bytes: [UInt8], tokens: [JSONToken], caret: Int) {
        source = Source(bytes: bytes, tokens: tokens, caret: caret)
    }

    mutating func read() -> JSONCaret? {
        let pieces = source.pieces
        while i < pieces.count, case .stray = pieces[i] { i += 1 }   // a byte order mark, say
        guard i < pieces.count, case .open(let isObject) = pieces[i], source.tokens[i].range.lowerBound < source.caret else { return nil }
        _ = container(isObject: isObject, component: nil, depth: 1)
        guard case .found = search else { return nil }
        found.path.reverse()
        found.containers.reverse()
        return found
    }

    /// Reads the object or array opening at the current token, to its closing bracket or where it
    /// ends without one. `component` is the step to it from its parent (nil for the root, or for
    /// one that's no member or element). Nil for one nested too deep, whose tokens are passed over.
    mutating func container(isObject: Bool, component: JSONPathComponent?, depth: Int) -> JSONNode? {
        isObject ? container(ObjectReading(), component: component, depth: depth) : container(ArrayReading(), component: component, depth: depth)
    }

    mutating func container<Reading: ContainerReading>(_ reading: Reading, component: JSONPathComponent?, depth: Int) -> JSONNode? {
        let source = source, tokens = source.tokens, caret = source.caret
        let first = i
        skip()
        guard depth <= JSONReader.maxDepth else {
            let closed = skipNested()
            // Still searching, the caret is past its opening bracket: in it, if it's before its
            // closing bracket or it has none (it's open to the end).
            if case .searching = search, !closed || caret < readTo { search = .lost }
            return nil
        }
        let wasSearching = if case .searching = search { true } else { false }
        let readsIndentation = source.readsIndentation
        let indent = readsIndentation ? lineIndent(of: first) : 0
        open.append(Opened(isObject: Reading.isObject, indent: indent))
        defer { open.removeLast() }

        var reading = reading
        var here: Here?
        var end = readTo
        // Where its content stops: the token it ends at (its closing bracket, or one of a container
        // around it), or the end.
        var contentEnd = tokens.count
        // Where its first line of content is indented, if that's a line of its own: a line indented
        // no further than its opening line, after that, is its parent's.
        var hasContent = false, bodyIndent: Int?
        let pieces = source.pieces
        while i < tokens.count {
            if case .lost = search { break }   // nothing's found, so the rest isn't needed
            var ending: Source.Ending?
            if case .close(let isObject) = pieces[i] {
                ending = source.ending(atClosing: i, isObject: isObject, in: open)
            } else if readsIndentation {
                if !hasContent {
                    hasContent = true
                    bodyIndent = source.indent(ofFirst: i)
                } else if let body = bodyIndent, body > indent, open.count > 1, pieces[i].startsValue,
                          let line = source.indent(ofFirst: i), line <= indent {
                    ending = .endsBefore
                }
            }
            if case .searching = search {
                if caret < readTo {
                    search = .lost
                } else if caret <= tokens[i].range.lowerBound {
                    here = reading.gap(before: i, endsHere: ending != nil, in: source)
                    search = here == nil ? .lost : .found
                }
            }
            if let ending {
                contentEnd = i
                if ending == .closes {
                    skip()
                    end = readTo
                }
                break
            }
            reading.read(&self, here: &here, depth: depth)
            end = readTo
        }
        if contentEnd == tokens.count, case .searching = search {
            // Left open to the end of the text, which the caret is in.
            here = caret < readTo ? nil : reading.gap(before: tokens.count, endsHere: true, in: source)
            search = here == nil ? .lost : .found
        }

        let node = reading.node(tokens[first].range.lowerBound..<end)
        if wasSearching, case .found = search {
            if let here {
                found = CaretReader.finish(here, reading.others, node: node, contentEnd: contentEnd, source)
            } else {
                found.containers.append(node)
            }
            if let component { found.path.append(component) }
        }
        return node
    }

    /// How far in the line token `k` is on is indented: the indentation of the last token at or
    /// before it that starts a line. Asked of tokens in order, it looks at each token once.
    mutating func lineIndent(of k: Int) -> Int {
        var t = k
        while t > lineRead.token {
            if let indent = source.indent(ofFirst: t) {
                lineRead = (k, indent)
                return indent
            }
            t -= 1
        }
        lineRead.token = k
        return lineRead.indent
    }

    /// The caret's facts, once its container is read whole: what follows it there, and the
    /// container's other members or elements.
    static func finish(_ here: Here, _ others: (siblings: [JSONMember], elements: [JSONNode]), node: JSONNode, contentEnd: Int,
                       _ source: Source) -> JSONCaret {
        let follows = here.next < contentEnd ? source.pieces[here.next] : nil
        let hasColon = here.isKey && follows == .colon
        return JSONCaret(path: [], position: here.position, replace: here.replace, query: here.query, isQuoted: here.isQuoted,
                         hasColon: hasColon, commaBefore: here.commaBefore, needsCommaAfter: !hasColon && (follows?.startsValue ?? false),
                         siblings: others.siblings, elements: others.elements, containers: [node])
    }

    mutating func skip() {
        readTo = source.tokens[i].range.upperBound
        i += 1
    }

    /// Passes over a container nested too deep, to its closing bracket or the end; whether it
    /// reached its closing bracket.
    mutating func skipNested() -> Bool {
        var level = 1
        while i < source.pieces.count, level > 0 {
            switch source.pieces[i] {
            case .open: level += 1
            case .close: level -= 1
            default: break
            }
            skip()
        }
        return level == 0
    }

    /// Reads the container opening at the current token as what it is where a key goes, or after
    /// a member with no comma: no member (`{ {…} }`), so a caret in it is nowhere.
    mutating func strayContainer(depth: Int) {
        guard case .open(let isObject) = source.pieces[i] else { return }
        let wasSearching = if case .searching = search { true } else { false }
        _ = container(isObject: isObject, component: nil, depth: depth + 1)
        if wasSearching, case .found = search { search = .lost }
    }
}

// MARK: Objects and arrays

private struct ObjectReading: ContainerReading {
    static let isObject = true

    enum Expect {
        case key
        /// A key's been read (token `token`); its colon comes next.
        case colon(name: String, keyRange: Range<Int>, token: Int)
        /// Its value comes next; `colonMissing` when no colon came between.
        case value(name: String, keyRange: Range<Int>, colonMissing: Bool)
        /// A member's been read, its value (or what's typed of one) ending at `end`; a comma comes
        /// next.
        case comma(end: Int)
    }

    var members: [JSONMember] = []
    var expect = Expect.key
    /// The end of the value before, which no comma followed, while the key after it is read.
    var commaMissing: Int?
    /// The member being read holds the caret, in its key or its value.
    var typing = false
    /// Which of `members` holds the caret.
    var typed: Int?

    func gap(before k: Int, endsHere: Bool, in source: Source) -> Here? {
        switch expect {
        case .key:
            return source.empty(.key, commaBefore: commaMissing, next: k)
        case .comma(let end):
            return source.empty(.key, commaBefore: end, next: k)
        case .colon:
            return nil
        case .value(let name, _, let colonMissing):
            // Only where the value is missing: nowhere before one.
            if colonMissing || (!endsHere && source.pieces[k].startsValue && !source.isKeyAhead(k)) { return nil }
            return source.empty(.value(of: name), commaBefore: nil, next: k)
        }
    }

    mutating func read(_ reader: inout CaretReader, here: inout Here?, depth: Int) {
        let source = reader.source, k = reader.i
        let piece = source.pieces[k]
        switch expect {
        case .key:
            switch piece {
            case .string, .word:
                typing = source.holdsCaret(k, reader.search)
                if typing {
                    here = source.partial(k, .key, commaBefore: commaMissing)
                    reader.search = .found
                }
                expect = .colon(name: source.name(k), keyRange: source.tokens[k].range, token: k)
                commaMissing = nil
                reader.skip()
            case .open:
                reader.strayContainer(depth: depth)
            case .comma:
                commaMissing = nil
                reader.skip()
            case .number:
                if source.holdsCaret(k, reader.search) { reader.search = .lost }
                reader.skip()
            case .colon, .close, .stray:
                reader.skip()
            }
        case .colon(let name, let keyRange, let keyToken):
            switch piece {
            case .colon:
                expect = .value(name: name, keyRange: keyRange, colonMissing: false)
                reader.skip()
            case .comma:
                expect = .key
                reader.skip()
            case .string, .word:
                // A key alone on its line, and the next line's string starts the next member; on
                // the same line, the value, its colon missing.
                expect = source.breaksLine(from: keyToken, to: k) ? .key : .value(name: name, keyRange: keyRange, colonMissing: true)
            case .number, .open:
                expect = .value(name: name, keyRange: keyRange, colonMissing: true)
            case .close, .stray:
                reader.skip()
            }
        case .value(let name, let keyRange, let colonMissing):
            if source.isKeyAhead(k) {
                expect = .key
                return
            }
            switch piece {
            case .string, .word, .number:
                if source.holdsCaret(k, reader.search) {
                    if colonMissing || piece == .number {
                        reader.search = .lost
                    } else {
                        typing = true
                        here = source.partial(k, .value(of: name), commaBefore: nil)
                        reader.search = .found
                    }
                }
                if let value = source.value(k) { append(JSONMember(key: name, keyRange: keyRange, value: value)) }
                reader.skip()
                expect = .comma(end: reader.readTo)
            case .open(let isObject):
                if let value = reader.container(isObject: isObject, component: .member(name), depth: depth + 1) {
                    append(JSONMember(key: name, keyRange: keyRange, value: value))
                }
                expect = .comma(end: reader.readTo)
            case .comma:
                expect = .key
                reader.skip()
            case .colon, .close, .stray:
                reader.skip()
            }
        case .comma(let end):
            switch piece {
            case .comma:
                expect = .key
                reader.skip()
            case .string, .word:
                // The next member, its comma missing.
                expect = .key
                commaMissing = end
            case .open:
                reader.strayContainer(depth: depth)
            case .number:
                if source.holdsCaret(k, reader.search) { reader.search = .lost }
                reader.skip()
            case .colon, .close, .stray:
                reader.skip()
            }
        }
    }

    mutating func append(_ member: JSONMember) {
        if typing { typed = members.count }
        members.append(member)
    }

    func node(_ range: Range<Int>) -> JSONNode { JSONNode(.object(members), range: range) }

    var others: (siblings: [JSONMember], elements: [JSONNode]) {
        var siblings = members
        if let typed { siblings.remove(at: typed) }
        return (siblings, [])
    }
}

private struct ArrayReading: ContainerReading {
    static let isObject = false

    var elements: [JSONNode] = []
    /// How many values have been written: the next one's index, whether each reads or not.
    var count = 0
    /// Where the last value ended, while no comma has followed it.
    var valueEnd: Int?
    /// Which of `elements` holds the caret.
    var typed: Int?

    func gap(before k: Int, endsHere: Bool, in source: Source) -> Here? {
        source.empty(.element(count), commaBefore: valueEnd, next: k)
    }

    mutating func read(_ reader: inout CaretReader, here: inout Here?, depth: Int) {
        let source = reader.source, k = reader.i
        let piece = source.pieces[k]
        // A value after one no comma followed: the comma's missing there.
        let commaMissing = piece.startsValue ? valueEnd : nil
        switch piece {
        case .string, .word, .number:
            var typing = false
            if source.holdsCaret(k, reader.search) {
                if piece == .number {
                    reader.search = .lost
                } else {
                    typing = true
                    here = source.partial(k, .element(count), commaBefore: commaMissing)
                    reader.search = .found
                }
            }
            if let value = source.value(k) {
                if typing { typed = elements.count }
                elements.append(value)
            }
            reader.skip()
        case .open(let isObject):
            if let value = reader.container(isObject: isObject, component: .element(count), depth: depth + 1) { elements.append(value) }
        case .comma:
            valueEnd = nil
            reader.skip()
            return
        case .colon, .close, .stray:
            reader.skip()
            return
        }
        count += 1
        valueEnd = reader.readTo
    }

    func node(_ range: Range<Int>) -> JSONNode { JSONNode(.array(elements), range: range) }

    var others: (siblings: [JSONMember], elements: [JSONNode]) {
        var others = elements
        if let typed { others.remove(at: typed) }
        return ([], others)
    }
}

private extension UInt8 {
    /// A letter, `_` or `$`: what the scanner starts a word with (a digit or `-` starts a number).
    var startsWord: Bool {
        (self >= UInt8(ascii: "a") && self <= UInt8(ascii: "z")) || (self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z"))
            || self == UInt8(ascii: "_") || self == UInt8(ascii: "$")
    }

    /// What a word being completed in a string can hold: anything but space, a quote, a backslash
    /// and JSON's punctuation (so `date-time`, `#/$defs/a`, `é`).
    var isWordByte: Bool {
        switch self {
        case 0x20, 0x09, 0x0A, 0x0D, UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "["),
             UInt8(ascii: "]"), UInt8(ascii: ":"), UInt8(ascii: ","):
            false
        default:
            true
        }
    }
}
