import Foundation
import QueryLanguage
import TestKit

/// Trees from the grammar, spans `nowhere`, each one the canonical form reads back to: a compound
/// after a space has a head, a title isn't blank, a bare value is one the lexer reads whole, and an
/// unknown word's argument is already as the printer writes it.
struct QueryGenerator {
    var random: SplitMix
    var depth = 0

    static let kinds = ["card", "box", "disc", "Card", "wide_card-2", "é-card", "i", "only", "_x"]
    static let names = ["rank", "status", "due", "my attr", "a.b", "x-y_z", "é", "\"q\""]
    /// Names that are identifiers, which can have members inside them, and the members.
    static let pathNames = ["rank", "status", "due", "x-y_z", "é"]
    static let members = ["x", "y_2", "é", "a-b", "only", "_", "Card"]
    static let types = ["wire", "hot-wire", "pipe", "only", "Wire"]
    static let unknownWords = ["glows", "stacked", "x-y", "a_b2"]
    static let junk = ["2n+1", "1, 2", "-x", "", "a b", #""x" y"#, "@q", "[a=:)]", "a[b"]
    static let textPieces = ["a", "B", " ", "\"", "'", "\\", "\n", ")", "(", "]", "[", ",", ":", "/*", "*/", "é", "👍🏽", "#", ">", "\t", "only"]
    static let bareCharacters = Array("abcXYZ019-._:,#*/+~|^$@&%")

    init(seed: UInt64) { random = SplitMix(seed: seed) }

    mutating func chance(_ percent: Int) -> Bool { Int.random(in: 0..<100, using: &random) < percent }
    mutating func pick<T>(_ items: [T]) -> T { items.randomElement(using: &random)! }
    mutating func count(_ range: ClosedRange<Int>) -> Int { Int.random(in: range, using: &random) }

    mutating func list() -> SelectorList {
        SelectorList((0..<count(1...(depth < 2 ? 3 : 1))).map { _ in complex() })
    }

    mutating func complex() -> ComplexSelector {
        var compounds = [compound(needsHead: false)]
        var combinators: [Combinator] = []
        for _ in 0..<count(0...(depth < 2 ? 2 : 1)) {
            let combinator: Combinator = chance(50) ? .child : .descendant
            combinators.append(combinator)
            compounds.append(compound(needsHead: combinator == .descendant))
        }
        return ComplexSelector(compounds: compounds, combinators: combinators, span: nowhere)
    }

    mutating func compound(needsHead: Bool) -> Compound {
        let head: Head? = needsHead || chance(70) ? self.head() : nil
        let filters = (0..<count((head == nil ? 1 : 0)...2)).map { _ in filter() }
        return Compound(head: head, filters: filters, span: nowhere)
    }

    mutating func head() -> Head {
        switch count(0...4) {
        case 0: return .kind(pick(Self.kinds), nowhere)
        case 1: return .any
        case 2: return .title(title(), nowhere)
        case 3: return .kindTitle(pick(Self.kinds), nowhere, title: title(), nowhere)
        default: return .id(UUID(), nowhere)
        }
    }

    /// A title: not blank.
    mutating func title() -> String {
        let title = text()
        return title.allSatisfy(\.isWhitespace) ? title + "x" : title
    }

    mutating func text() -> String {
        (0..<count(1...5)).map { _ in pick(Self.textPieces) }.joined()
    }

    mutating func filter() -> Filter {
        guard chance(50) else { return .pseudo(pseudo()) }
        let inside = chance(25)
        let name = inside ? pick(Self.pathNames) : pick(Self.names)
        let path = inside ? (0..<count(1...3)).map { _ in pick(Self.members) } : []
        guard chance(75) else { return .attribute(AttributeTest(name: name, path: path, span: nowhere)) }
        let value: Literal = chance(50) ? .quoted(chance(20) ? "" : text()) : .bare(bare())
        return .attribute(AttributeTest(name: name, path: path, op: pick(Operator.allCases), value: value, flag: chance(30) ? pick(CaseFlag.allCases) : nil, span: nowhere))
    }

    /// Characters the lexer reads as one bare value: not starting with an operator's, and no `/*`.
    mutating func bare() -> String {
        var value = String(pick(Self.bareCharacters.filter { !"=<>!".contains($0) }))
        for _ in 0..<count(0...4) {
            let next = pick(Self.bareCharacters)
            if value.last == "/", next == "*" { continue }
            value.append(next)
        }
        return value
    }

    mutating func pseudo() -> PseudoClass {
        let deeper = depth < 3
        depth += 1
        defer { depth -= 1 }
        let word = deeper && chance(80) ? pick(Word.allCases) : nil
        guard let word else {
            let name = pick(Self.unknownWords)
            let argument: PseudoArgument = switch count(0...2) {
            case 0: .none
            case 1 where deeper: .raw(list().canonical, nowhere)
            default: .raw(pick(Self.junk), nowhere)
            }
            return PseudoClass(name: name, argument: argument, span: nowhere, nameSpan: nowhere)
        }
        let argument: PseudoArgument = switch word.signature {
        case .none: .none
        case .selectors: .selectors(list())
        case .has: .has((0..<count(1...2)).map { _ in HasItem(child: chance(50), compound: compound(needsHead: false)) })
        case .anchor: .anchored([complex()], types: chance(50) ? typeList() : nil)
        case .twoAnchors: .anchored([complex(), complex()], types: chance(50) ? typeList() : nil)
        case .types: chance(50) ? .none : .types(typeList())
        case .text: .text(text())
        }
        return PseudoClass(name: word.rawValue, argument: argument, span: nowhere, nameSpan: nowhere)
    }

    mutating func typeList() -> [TypeTerm] {
        (0..<count(1...3)).map { _ in TypeTerm(name: pick(Self.types), only: chance(30), span: nowhere) }
    }
}

/// Where every span in a tree is, to hold them inside the text.
func spans(of list: SelectorList) -> [QuerySpan] {
    list.selectors.flatMap { complex in
        [complex.span] + complex.compounds.flatMap { compound -> [QuerySpan] in
            var found = [compound.span]
            switch compound.head {
            case .kind(_, let span), .title(_, let span), .id(_, let span): found.append(span)
            case .kindTitle(_, let kind, _, let title): found += [kind, title]
            case .any, nil: break
            }
            for filter in compound.filters {
                switch filter {
                case .attribute(let test): found.append(test.span)
                case .pseudo(let pseudo):
                    found += [pseudo.span, pseudo.nameSpan]
                    switch pseudo.argument {
                    case .selectors(let inner): found += spans(of: inner)
                    case .has(let items): found += spans(of: SelectorList(items.map { ComplexSelector(compounds: [$0.compound], span: $0.compound.span) }))
                    case .anchored(let anchors, let types): found += spans(of: SelectorList(anchors)) + (types ?? []).map(\.span)
                    case .types(let types): found += types.map(\.span)
                    case .raw(_, let span): found.append(span)
                    case .none, .text: break
                    }
                }
            }
            return found
        }
    }
}

/// Every pseudo-class in a tree, arguments' included.
func pseudos(in list: SelectorList) -> [PseudoClass] {
    list.selectors.flatMap(\.compounds).flatMap { compound in
        compound.filters.flatMap { filter -> [PseudoClass] in
            guard case .pseudo(let pseudo) = filter else { return [] }
            return switch pseudo.argument {
            case .selectors(let inner): [pseudo] + pseudos(in: inner)
            case .has(let items): [pseudo] + pseudos(in: SelectorList(items.map { ComplexSelector(compounds: [$0.compound], span: $0.compound.span) }))
            case .anchored(let anchors, _): [pseudo] + pseudos(in: SelectorList(anchors))
            case .none, .types, .text, .raw: [pseudo]
            }
        }
    }
}

/// What one edited text came to: whether it was refused, and what is wrong with how it was read or refused, if anything.
struct EditOutcome: Sendable {
    var refused = false
    var failure: String?
}

/// The outcomes of the slices of texts read at once, each set by the slice that made it.
final class Outcomes: @unchecked Sendable {
    private let lock = NSLock()
    private var slices: [[EditOutcome]]
    init(_ count: Int) { slices = Array(repeating: [], count: count) }
    func set(_ slice: Int, _ outcomes: [EditOutcome]) { lock.withLock { slices[slice] = outcomes } }
    var all: [[EditOutcome]] { lock.withLock { slices } }
}

/// Reads `text`, which an edit left as it is: what reads prints its own canonical form, and a refusal is inside the text.
func editOutcome(_ text: String) -> EditOutcome {
    let count = text.count
    var outcome = EditOutcome()
    do throws(QueryError) {
        let read = try SelectorList(parsing: text)
        let canonical = read.canonical
        let again = try SelectorList(parsing: canonical)
        let third = try SelectorList(parsing: again.canonical)
        var outside = spans(of: read).filter { $0.offset < 0 || $0.length < 0 || $0.end > count }
        for pseudo in pseudos(in: read) where pseudo.word == nil {
            // A plugin's relation reads its argument; an invention is refused. Either says where, in this text.
            do throws(QueryError) {
                outside += spans(of: try SelectorList(argumentOf: pseudo)).filter { $0.offset < 0 || $0.length < 0 || $0.end > count }
            } catch {
                if let span = error.span, span.offset < 0 || span.length < 1 || span.end > count { outside.append(span) }
            }
            if let span = KnownInventions.error(for: pseudo)?.span, span.offset < 0 || span.length < 1 || span.end > count { outside.append(span) }
        }
        if again.canonical != canonical || third != again || !outside.isEmpty {
            outcome.failure = "\(text.debugDescription) read, but its canonical form \(canonical.debugDescription) doesn't hold"
        }
    } catch {
        outcome.refused = true
        let inside: Bool = if let span = error.span {
            span.offset >= 0 && span.length >= 1 && span.end <= count && error.located(in: text) != nil
        } else {
            error.reason == .emptyQuery
        }
        let syntactic: Set<QueryError.Reason> = [.emptyQuery, .syntax, .straySpace, .tooLong, .tooComplex, .unsupported, .notBuilt, .notAnID,
                                                 .badArgument]
        if !inside || !syntactic.contains(error.reason) || !error.errors.isEmpty {
            outcome.failure = "\(text.debugDescription): \(error) at \(String(describing: error.span))"
        }
    }
    return outcome
}

@MainActor let fuzzTests = Suite("Fuzz", [
    test("2,000 trees from the grammar print a form that reads back to them, and is its own canonical form") {
        var generator = QueryGenerator(seed: 0x7175_6572_7973)
        var failures = 0
        for _ in 0..<2_000 {
            let tree = generator.list()
            let text = tree.canonical
            do throws(QueryError) {
                let read = try SelectorList(parsing: text)
                let again = try SelectorList(parsing: read.canonical)
                if stripped(read) != tree || read.canonical != text || again != read {
                    failures += 1
                    if failures < 4 { expect(false, "\(text.debugDescription) read back as \(read.canonical.debugDescription)") }
                }
            } catch {
                failures += 1
                if failures < 4 { expect(false, "\(text.debugDescription) was refused: \(error)") }
            }
        }
        expectEqual(failures, 0)
    },
    test("20,000 random edits of queries never crash; what reads prints its own canonical form, and every refusal is inside the text") {
        var generator = QueryGenerator(seed: 0x6564_6974_73)
        let hostile = ["(", ")", "[", "]", "\"", "'", "\\", ":", "::", ",", ">", "+", "~", "|", "||", "*", "#", ".", "/", "/*", "*/", " ", "\n", "\r\n",
                       "=", "==", "!", "@", "&", "$", "\u{201C}", "é", "\u{301}", "👍🏽", "a", "0", "-", "i", "only ", ":not(", ":has(", ":has(>",
                       ":edge-to(", ":between(", ":contains(", ":dangling(", ":glows(", ":nth-child(", ":parent-of(", ":root", ":stacked( ",
                       "#00000000-0000-4000-8000-000000000011"]
        // The edits are made in order from the one generator; each text is then read on its own, so the reading is spread over the cores.
        var texts: [String] = []
        texts.reserveCapacity(20_000)
        for round in 0..<20_000 {
            var characters = Array(round % 4 == 0 ? generator.list().canonical : generator.list().canonical.replacingOccurrences(of: "\"", with: "'"))
            for _ in 0..<generator.count(1...3) {
                let at = generator.count(0...characters.count)
                switch generator.count(0...3) {
                case 0: characters.insert(contentsOf: generator.pick(hostile), at: at)
                case 1: if at < characters.count { characters.remove(at: at) }
                case 2: if at < characters.count { characters[at] = Character(generator.pick(hostile.filter { $0.count == 1 })) }
                default: characters.removeLast(min(characters.count - at, generator.count(0...3)))
                }
            }
            texts.append(String(characters))
        }
        let all = texts, slices = 64, per = (all.count + slices - 1) / slices
        let outcomes = Outcomes(slices)
        DispatchQueue.concurrentPerform(iterations: slices) { slice in
            outcomes.set(slice, all[slice * per..<min((slice + 1) * per, all.count)].map(editOutcome))
        }
        var failures = 0
        var refused = 0
        for outcome in outcomes.all.joined() {
            if outcome.refused { refused += 1 }
            if let failure = outcome.failure {
                failures += 1
                if failures < 4 { expect(false, failure) }
            }
        }
        expectEqual(failures, 0)
        expect(refused > 5_000 && refused < 19_000, "the edits both break and keep queries: \(refused) refused")
    },
])
