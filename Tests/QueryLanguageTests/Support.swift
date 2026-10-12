import Foundation
import QueryLanguage
import TestKit

// Fixture words only: kinds (card, box, disc), attributes (rank, status, due), edge types (wire,
// hot-wire, pipe) and unknown words (glows, stacked). Titles are the example file's ("Payments").

/// Reads a query.
func parse(_ text: String) throws -> SelectorList {
    try SelectorList(parsing: text)
}

/// Why a query is refused; nil if it reads.
func refusal(_ text: String) -> QueryError? {
    do throws(QueryError) {
        _ = try SelectorList(parsing: text)
        return nil
    } catch {
        return error
    }
}

func at(_ offset: Int, _ length: Int) -> QuerySpan { QuerySpan(offset: offset, length: length) }

// MARK: Trees without spans

/// Where a tree built here is: nowhere. Compare with `stripped` trees.
let nowhere = QuerySpan(offset: 0, length: 0)

func list(_ selectors: ComplexSelector...) -> SelectorList { SelectorList(selectors) }

/// A complex selector: the first compound, then each combinator with the compound after it.
func complex(_ first: Compound, _ rest: (Combinator, Compound)...) -> ComplexSelector {
    ComplexSelector(compounds: [first] + rest.map(\.1), combinators: rest.map(\.0), span: nowhere)
}

func compound(_ head: Head?, _ filters: Filter...) -> Compound { Compound(head: head, filters: filters, span: nowhere) }
func kind(_ name: String) -> Head { .kind(name, nowhere) }
func titled(_ title: String) -> Head { .title(title, nowhere) }
func kind(_ name: String, titled title: String) -> Head { .kindTitle(name, nowhere, title: title, nowhere) }
func id(_ text: String) -> Head { .id(UUID(uuidString: text)!, nowhere) }

func attribute(_ name: String, _ op: Operator? = nil, _ value: Literal? = nil, _ flag: CaseFlag? = nil) -> Filter {
    .attribute(AttributeTest(name: name, op: op, value: value, flag: flag, span: nowhere))
}

/// `[name.a.b op value flag]`: members inside the attribute.
func attribute(_ name: String, in path: [String], _ op: Operator? = nil, _ value: Literal? = nil, _ flag: CaseFlag? = nil) -> Filter {
    .attribute(AttributeTest(name: name, path: path, op: op, value: value, flag: flag, span: nowhere))
}

func pseudo(_ name: String, _ argument: PseudoArgument = .none) -> Filter {
    .pseudo(PseudoClass(name: name, argument: argument, span: nowhere, nameSpan: nowhere))
}

func type(_ name: String, only: Bool = false) -> TypeTerm { TypeTerm(name: name, only: only, span: nowhere) }

/// A one-compound query.
func single(_ head: Head?, _ filters: Filter...) -> SelectorList {
    SelectorList([ComplexSelector(compounds: [Compound(head: head, filters: filters, span: nowhere)], span: nowhere)])
}

/// The tree with every span set to `nowhere`, to compare with a tree built here.
func stripped(_ list: SelectorList) -> SelectorList {
    SelectorList(list.selectors.map(stripped))
}

func stripped(_ complex: ComplexSelector) -> ComplexSelector {
    ComplexSelector(compounds: complex.compounds.map(stripped), combinators: complex.combinators, span: nowhere)
}

func stripped(_ compound: Compound) -> Compound {
    let head: Head? = switch compound.head {
    case .kind(let name, _): .kind(name, nowhere)
    case .title(let title, _): .title(title, nowhere)
    case .kindTitle(let name, _, let title, _): .kindTitle(name, nowhere, title: title, nowhere)
    case .id(let id, _): .id(id, nowhere)
    case .any: .any
    case nil: nil
    }
    return Compound(head: head, filters: compound.filters.map(stripped), span: nowhere)
}

func stripped(_ filter: Filter) -> Filter {
    switch filter {
    case .attribute(var test):
        test.span = nowhere
        return .attribute(test)
    case .pseudo(let pseudo):
        let argument: PseudoArgument = switch pseudo.argument {
        case .none: .none
        case .selectors(let list): .selectors(stripped(list))
        case .has(let items): .has(items.map { HasItem(child: $0.child, compound: stripped($0.compound)) })
        case .anchored(let anchors, let types): .anchored(anchors.map(stripped), types: types.map { $0.map(stripped) })
        case .types(let types): .types(types.map(stripped))
        case .text(let text): .text(text)
        case .raw(let text, _): .raw(text, nowhere)
        }
        return .pseudo(PseudoClass(name: pseudo.name, argument: argument, span: nowhere, nameSpan: nowhere))
    }
}

func stripped(_ term: TypeTerm) -> TypeTerm { TypeTerm(name: term.name, only: term.only, span: nowhere) }

// MARK: Checks

/// Reads a query and holds its canonical form to `canonical`, and that form to reading back to
/// itself, tree and all. `sameTree`: the query read as written is the tree its canonical form reads
/// to, spans aside (not so for an unknown word's argument, kept as written).
@MainActor func expectCanonical(_ text: String, _ canonical: String, sameTree: Bool = true, file: StaticString = #fileID, line: UInt = #line) {
    do {
        let read = try parse(text)
        expectEqual(read.canonical, canonical, text, file: file, line: line)
        let again = try parse(read.canonical)
        if sameTree { expectEqual(stripped(again), stripped(read), "the canonical form reads to the same tree: \(text)", file: file, line: line) }
        expectEqual(again.canonical, read.canonical, "the canonical form is its own: \(text)", file: file, line: line)
        expectEqual(try parse(again.canonical), again, "read from its canonical form, the tree prints and reads back whole", file: file, line: line)
    } catch {
        expect(false, "\(text) was refused: \(error)", file: file, line: line)
    }
}

/// A refusal, pinned: its reason, message, hint and span, and where `located` puts it; and a better
/// hint that waits on the caller (`better`), for compounds it takes to hold shapes (`holding`, as
/// written canonically), or for a word that names a type (`typeWord`, the name as written).
struct Refused {
    var query: String
    var reason: QueryError.Reason
    var message: String
    var hint: String?
    var better: String?
    var holding: [String]?
    var typeWord: String?
    var offset: Int?
    var length: Int?
    var line = 1
    var column: Int?

    init(_ query: String, _ reason: QueryError.Reason, _ message: String, hint: String? = nil, better: String? = nil, holding: [String]? = nil,
         typeWord: String? = nil, at offset: Int? = nil, _ length: Int? = nil, line: Int = 1, column: Int? = nil) {
        self.query = query
        self.reason = reason
        self.message = message
        self.hint = hint
        self.better = better
        self.holding = holding
        self.typeWord = typeWord
        self.offset = offset
        self.length = length
        self.line = line
        self.column = column ?? offset.map { $0 + 1 }
    }
}

@MainActor func expectRefused(_ cases: [Refused], file: StaticString = #fileID, line: UInt = #line) {
    for expected in cases {
        guard let error = refusal(expected.query) else {
            expect(false, "\(expected.query.debugDescription) was read", file: file, line: line)
            continue
        }
        let what = expected.query.debugDescription
        expectEqual(error.reason, expected.reason, what, file: file, line: line)
        expectEqual(error.message, expected.message, what, file: file, line: line)
        expectEqual(error.hint, expected.hint, what, file: file, line: line)
        expectEqual(error.premise?.hint, expected.better, "the better hint: \(what)", file: file, line: line)
        let holding: [String]? = if case .holdShapes(let compounds)? = error.premise?.claim { compounds.map(\.canonical) } else { nil }
        expectEqual(holding, expected.holding, "what the better hint takes to hold shapes: \(what)", file: file, line: line)
        let typeWord: String? = if case .typeWord(let name)? = error.premise?.claim { name } else { nil }
        expectEqual(typeWord, expected.typeWord, "the type a hint may write as a word: \(what)", file: file, line: line)
        expectEqual(error.span?.offset, expected.offset, what, file: file, line: line)
        expectEqual(error.span?.length, expected.length, what, file: file, line: line)
        expectEqual(error.errors, [], "reading stops at the first: \(what)", file: file, line: line)
        if let located = error.located(in: expected.query) {
            expectEqual(located.line, expected.line, what, file: file, line: line)
            expectEqual(located.column, expected.column, what, file: file, line: line)
        } else {
            expectEqual(expected.offset, nil, "\(what) has no place", file: file, line: line)
        }
        // A query a hint offers reads, or is refused for the reason the query it mends is.
        for offered in offeredQueries(in: error.hint) + offeredQueries(in: error.premise?.hint) {
            if let again = refusal(offered), again.reason != error.reason {
                expect(false, "\(what)'s hint offers \(offered.debugDescription), which is refused: \(again)", file: file, line: line)
            }
        }
    }
}

/// The queries a hint offers: the hint itself, or a clause of it (between semicolons and sentences'
/// ends) or what follows its last colon, or what comes before "finds", "lists", "is" or "asks" in
/// one of those, less a sentence's end, whichever reads as a query and looks like one (a quote, a
/// bracket, a colon, `#`, `*` or `>`, and no two words in a row; or the whole hint, one word): so a
/// list of words ("Its attributes: a, b"), a sentence ("Did you mean wire or hot-wire?") and a name
/// suggested ("Did you mean "Ledger"?") aren't, though they read.
func offeredQueries(in hint: String?) -> [String] {
    guard let hint else { return [] }
    func sentenceEnd(_ text: Substring) -> String {
        var text = text.trimmingCharacters(in: .whitespaces)
        while let last = text.last, ".?".contains(last) { text.removeLast() }
        return text
    }
    func reads(_ text: String) -> Bool { (try? SelectorList(parsing: text)) != nil }
    func isWord(_ token: Substring) -> Bool { token.first?.isLetter == true && token.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
    func looksLikeQuery(_ text: String) -> Bool {
        let tokens = text.split(separator: " ")
        return text.contains { "\"'[:#*>".contains($0) } && !zip(tokens, tokens.dropFirst()).contains { isWord($0) && isWord($1) }
    }
    let whole = sentenceEnd(hint[...])
    if reads(whole), looksLikeQuery(whole) || !whole.contains(" ") { return [whole] }
    var clauses: [Substring] = []
    for sentence in hint.split(separator: "; ") {
        var rest = sentence[...]
        while let end = [rest.range(of: ". "), rest.range(of: "? ")].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) {
            clauses.append(rest[..<end.lowerBound])
            rest = rest[end.upperBound...]
        }
        clauses.append(rest)
    }
    var offered: [String] = []
    for clause in clauses {
        var candidates = [sentenceEnd(clause)]
        if let colon = clause.range(of: ": ", options: .backwards) { candidates.append(sentenceEnd(clause[colon.upperBound...])) }
        for candidate in candidates {
            for verb in [" finds ", " lists ", " is ", " asks "] {
                if let found = candidate.range(of: verb) { candidates.append(String(candidate[..<found.lowerBound])) }
            }
        }
        if let query = candidates.first(where: { looksLikeQuery($0) && reads($0) }), !offered.contains(query) { offered.append(query) }
    }
    return offered
}

// MARK: Random

/// A deterministic generator, so the fuzz is the same every run.
struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
