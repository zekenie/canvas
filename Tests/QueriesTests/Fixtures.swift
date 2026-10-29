import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import os
import Queries
import QueryLanguage
import TestKit
import Topology

// Fixtures of Queries' tests' own, over CanvasTesting's chores, pockets, corrals, tiles and links,
// never a real plugin's: links are wires (a grade makes one hot, a kind of wire, or loose, a tether,
// which nobody declares); a caption names chores, pockets and (in the yard) corrals, and a tile's
// name is derived from its label;
// an untitled pocket's board is an "Untitled Pocket"; the words are :starred (a set taken up with
// the file), :heavy (worked out anywhere), :audited (on the main actor) and :wired-to(S) (a
// relation over wires); and a shout, text read in capitals.

// MARK: Edges

enum WireEdge {}
extension WireEdge: EdgeType {
    static let id: EdgeTypeID = "wire"
    static let summary: String? = "a link, from the shape it starts on to the shape it ends on"
}

enum HotWireEdge {}
extension HotWireEdge: EdgeType {
    static let id: EdgeTypeID = "hot-wire"
    static var parent: EdgeTypeID? { WireEdge.id }
    static let summary: String? = "a link graded hot"
}

/// What a loose link carries, which no plugin declares.
let tether: EdgeTypeID = "tether"

/// How a link carries: a wire, a hot wire, or loose (a tether).
enum Grade {}
extension Grade: ShapeProperty {
    static let key: PropertyKey = "grade"
    static var defaultValue: LinkGrade? { nil }
}

enum LinkGrade: String, Codable, Sendable, SchemaCases {
    case plain, hot, loose
    var schemaTitle: String { rawValue.capitalized }
}

/// The edge types, and links as their carriers.
func graphPlugin() -> Contributor {
    Contributor(id: "graph") { registrar in
        registrar.edgeType(WireEdge.self)
        registrar.edgeType(HotWireEdge.self)
        registrar.declare(Grade.self)
        registrar.optIn(Link.self, to: Grade.self)
        registrar.edges(Link.self) { record, _, sink in
            guard let link = record.props as? Link, let from = link.from, let to = link.to else { return }
            let type = switch record[Grade.self] {
            case .hot?: HotWireEdge.id
            case .loose?: tether
            default: WireEdge.id
            }
            sink.emit(type, from: from, to: to)
        }
    }
}

// MARK: Names

/// What a chore or a pocket is called: nil until one is given.
enum Caption {}
extension Caption: ShapeProperty {
    static let key: PropertyKey = "caption"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> { PropertyKeywords().maxLength(40) }
    static func isNone(_ value: String) -> Bool { value.allSatisfy(\.isWhitespace) }
}

/// Captions, which chores and pockets hold.
func captionsPlugin() -> Contributor {
    Contributor(id: "captions") { registrar in
        registrar.declare(Caption.self)
        registrar.optIn(Chore.self, to: Caption.self)
        registrar.optIn(Pocket.self, to: Caption.self)
    }
}

/// Corrals hold captions too, where they're installed.
func corralCaptionsPlugin() -> Contributor {
    Contributor(id: "corral-captions") { $0.optIn(Corral.self, to: Caption.self) }
}

/// How often the main actor was asked for what only it answers.
@MainActor
final class MainCalls {
    var derived = 0
    var prepared: [String: Int] = [:]
    var onMain = 0
}

/// How often something was asked anywhere.
final class Tally: Sendable {
    private let total = OSAllocatedUnfairLock(initialState: 0)

    func add() { total.withLock { $0 += 1 } }

    var count: Int { total.withLock { $0 } }
}

/// A caption, folded: one line, trimmed; nil for none.
@Sendable func folded(_ text: String?) -> String? {
    guard let text else { return nil }
    let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return line.isEmpty ? nil : line
}

/// Shapes named by captions (chores and pockets) and tiles by their labels (derived, on the main
/// actor), tested as `[caption…]`.
func namesPlugin(_ calls: MainCalls = MainCalls()) -> Contributor {
    Contributor(id: "names") { registrar in
        registrar.queryNames(attribute: Caption.key.rawValue,
                             source: { kind, registry in
                                 kind == Tile.kind ? .derived : registry.properties(for: kind).contains(Caption.key) ? .named : .none
                             },
                             named: { folded($0[Caption.self]) },
                             derived: { record, _ in
                                 calls.derived += 1
                                 return folded((record.props as? Tile)?.label)
                             },
                             fold: { folded($0) })
    }
}

/// An untitled pocket's board is an "Untitled Pocket".
func boardNamesPlugin() -> Contributor {
    Contributor(id: "board-names") { registrar in
        registrar.queryBoardNames { kind, _ in kind == Pocket.kind ? "Untitled Pocket" : nil }
    }
}

// MARK: Words

/// The words: `:starred` (the shapes in `starred` as the query takes up the file: seeds), `:heavy`
/// (a chore of estimate 5 or more, worked out anywhere), `:audited` (a flagged shape, which only the
/// main actor says), and `:wired-to(S)` (a wire to a shape S matches).
func wordsPlugin(starred: @escaping @MainActor () -> Set<ShapeID> = { [] }, calls: MainCalls = MainCalls(),
                 heavy: Tally = Tally()) -> Contributor {
    Contributor(id: "words") { registrar in
        registrar.queryPseudoClass("starred", "someone starred it", example: ":starred",
                                   prepare: { _ in
                                       calls.prepared["starred", default: 0] += 1
                                       return starred()
                                   },
                                   seeds: { $0 },
                                   matches: { shape, stars in stars.contains(shape.record.id) ? .yes : .no })
        registrar.queryPseudoClass("heavy", "a chore of estimate 5 or more", example: "chore:heavy",
                                   prepare: { _ in () },
                                   matches: { shape, _ in
                                       heavy.add()
                                       return ((shape.record.props as? Chore)?.estimate ?? 0) >= 5 ? .yes : .no
                                   })
        registrar.queryPseudoClass("audited", "someone flagged it", example: ":audited",
                                   prepare: { _ in () },
                                   matches: { _, _ in .onMain },
                                   onMain: { record, _, _, _ in
                                       calls.onMain += 1
                                       return record[Flagged.self] == true
                                   })
        registrar.queryRelation("wired-to", "it has a wire to a shape the query matches", example: #":wired-to("Pantry")"#,
                                types: [WireEdge.id], direction: .outgoing)
    }
}

// MARK: Text formats

/// Text that reads in capitals, which chores hold.
enum Shout {}
extension Shout: ShapeProperty {
    static let key: PropertyKey = "shout"
    static var defaultValue: String? { nil }
    static var keywords: PropertyKeywords<String> { PropertyKeywords().keywords(["contentMediaType": .string(shoutType)]) }
}

let shoutType = "text/x-shout"

/// Shouts, and how they read.
func shoutsPlugin() -> Contributor {
    Contributor(id: "shouts") { registrar in
        registrar.declare(Shout.self)
        registrar.optIn(Chore.self, to: Shout.self)
        registrar.queryTextFormat(mediaType: shoutType, describes: "read in capitals", prepare: { _ in () },
                                  read: { text, _ in text.uppercased() })
    }
}

// MARK: Lists and files

/// The fixtures, Topology and Queries, and `more` after them: every point filled.
@MainActor func queryPlugins(names: Bool = true, words: Bool = true, more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [ChoresPlugin(), PocketsPlugin(), TilesPlugin(), LinksPlugin(), TopologyPlugin(), QueriesPlugin(), graphPlugin(), captionsPlugin()]
        + (names ? [namesPlugin(), boardNamesPlugin()] : [])
        + (words ? [wordsPlugin(), shoutsPlugin()] : [])
        + more
}

let unit = CGRect(x: 0, y: 0, width: 100, height: 60)

func chore(_ id: ShapeID, caption: String? = nil, _ props: Chore = Chore(unit)) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, props))
    record[Caption.self] = caption
    return record
}

func pocket(_ id: ShapeID, caption: String? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, Pocket(unit)))
    record[Caption.self] = caption
    return record
}

func corral(_ id: ShapeID, caption: String? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, Corral(unit)))
    record[Caption.self] = caption
    return record
}

/// The record, in `container` on its board.
func held(_ record: AnyShapeRecord, in container: ShapeID) -> AnyShapeRecord { record.copy(as: record.id, container: container) }

func tile(_ id: ShapeID, label: String) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Tile(unit, label: label))) }

func link(_ id: ShapeID, _ from: ShapeID, _ to: ShapeID, grade: LinkGrade? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to)))
    record[Grade.self] = grade
    return record
}

func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

/// A file: on the top board, chore 1 "Alpha", pocket 2 "Pantry", a wire 3 from 1 to 2 and a loose
/// link 4 from 2 to 1 (a tether); on the pantry's board, chore 11 "Beta" and pocket 12, untitled;
/// on its board, chore 21 and tile 22 "Tiled".
struct Shelf {
    var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha"), pocket(id(2), caption: "Pantry"), link(id(3), id(1), id(2)),
                                                 link(id(4), id(2), id(1), grade: .loose)]),
                   children: [id(2): CanvasDocument(shapes: [chore(id(11), caption: "Beta"), pocket(id(12))]),
                              id(12): CanvasDocument(shapes: [chore(id(21)), tile(id(22), label: "Tiled")])])
    }
}

@MainActor func shelf(names: Bool = true, words: Bool = true, more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: queryPlugins(names: names, words: words, more: more), file: Shelf().file)
}

/// Containers within boards: on the top board, chore 1 "Alpha"; corral 5 "Pen" holding chore 6
/// "Gamma", corral 7 (untitled) holding chore 8, and pocket 2 "Pantry"; then chore 9 and a wire 3
/// from 1 to 6, in nothing. On the pantry's board, corral 15 "Bin" holding chore 16 "Delta" and
/// pocket 12 (untitled), whose board holds chore 21; and chore 11 "Beta", in nothing. In file order:
/// 1, 5, 6, 7, 8, 2, 15, 16, 12, 21, 11, 9, 3.
struct Yard {
    static let fileOrder = [1, 5, 6, 7, 8, 2, 15, 16, 12, 21, 11, 9, 3]

    var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha"), corral(id(5), caption: "Pen"),
                                                 held(chore(id(6), caption: "Gamma"), in: id(5)), held(corral(id(7)), in: id(5)),
                                                 held(chore(id(8)), in: id(7)), held(pocket(id(2), caption: "Pantry"), in: id(5)), chore(id(9)),
                                                 link(id(3), id(1), id(6))]),
                   children: [id(2): CanvasDocument(shapes: [corral(id(15), caption: "Bin"), held(chore(id(16), caption: "Delta"), in: id(15)),
                                                             held(pocket(id(12)), in: id(15)), chore(id(11), caption: "Beta")]),
                              id(12): CanvasDocument(shapes: [chore(id(21))])])
    }
}

/// The fixtures with corrals, captioned, on the yard.
@MainActor func yard(more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: queryPlugins(more: [CorralsPlugin(), corralCaptionsPlugin()] + more), file: Yard().file)
}

/// A file read from a board file: on the top board, chore 1, a gadget 10 (a kind nobody installs,
/// kept aside) whose board, which the app can't show, holds chore 11, and pocket 20 of a version
/// newer than the app's (kept aside too), whose board holds chore 21.
@MainActor func hiddenShelf() throws -> EditorHarness {
    func frame() -> String { "\"frame\" : [[0, 0], [1, 1]]" }
    let json = """
    { "format" : 4, "versions" : { "kinds" : { "chore" : 0, "pocket" : 99 } },
      "shapes" : [ { "id" : "\(uuid(1))", "kind" : "chore", "index" : "a0", "props" : { \(frame()) } },
                   { "id" : "\(uuid(10))", "kind" : "gadget", "index" : "a1", "props" : { } },
                   { "id" : "\(uuid(20))", "kind" : "pocket", "index" : "a2", "props" : { \(frame()) } } ],
      "boards" : {
        "\(uuid(10))" : { "shapes" : [ { "id" : "\(uuid(11))", "kind" : "chore", "index" : "a0", "props" : { \(frame()) } } ] },
        "\(uuid(20))" : { "shapes" : [ { "id" : "\(uuid(21))", "kind" : "chore", "index" : "a0", "props" : { \(frame()) } } ] }
      } }
    """
    let plugins = queryPlugins()
    let loaded = try BoardCodec(registry: Registry(plugins: plugins)).decode(Data(json.utf8))
    return try EditorHarness(plugins: plugins, file: loaded.file)
}

// MARK: Checking queries

/// A query resolved on `h`'s editor.
@MainActor func plan(_ text: String, on h: EditorHarness) throws -> QueryPlan {
    do throws(QueryError) {
        return try h.editor.queries!.check(text)
    } catch {
        expect(false, "\(text) is refused: \(error)")
        throw error
    }
}

/// Why `h`'s editor refuses a query; nil if it resolves.
@MainActor func refusal(_ text: String, on h: EditorHarness) -> QueryError? {
    do throws(QueryError) {
        _ = try h.editor.queries!.check(text)
        return nil
    } catch {
        return error
    }
}

/// A refusal expected: its reason, message, hint and where (offset and length in the query).
struct Refused {
    let query: String
    let reason: QueryError.Reason
    let message: String
    let hint: String?
    let span: QuerySpan?
    let file: StaticString
    let line: UInt

    init(_ query: String, _ reason: QueryError.Reason, _ message: String, hint: String? = nil, at offset: Int, _ length: Int,
         file: StaticString = #fileID, line: UInt = #line) {
        self.query = query
        self.reason = reason
        self.message = message
        self.hint = hint
        span = QuerySpan(offset: offset, length: length)
        self.file = file
        self.line = line
    }
}

/// Each query refused as it says, alone (its first problem, and no other); and each query its hint
/// offers answered, or refused for the reason it is (`expectOfferedAnswered`).
@MainActor func expectRefused(_ cases: [Refused], on h: EditorHarness) {
    for refused in cases {
        guard let error = refusal(refused.query, on: h) else {
            expect(false, "\(refused.query) resolves", file: refused.file, line: refused.line)
            continue
        }
        expectEqual(error.reason, refused.reason, refused.query, file: refused.file, line: refused.line)
        expectEqual(error.message, refused.message, refused.query, file: refused.file, line: refused.line)
        expectEqual(error.hint, refused.hint, refused.query, file: refused.file, line: refused.line)
        expectEqual(error.span, refused.span, refused.query, file: refused.file, line: refused.line)
        expectEqual(error.errors.count, 0, "\(refused.query): \(error.errors)", file: refused.file, line: refused.line)
        expectOfferedAnswered(refused.query, error, on: h, file: refused.file, line: refused.line)
    }
}

/// Each query a refusal's hint offers (`offeredQueries`) is answered on `h`, or refused for the
/// reason the query it mends is, or for a name the query wrote just so (a kind, title, id,
/// attribute, edge type or word that isn't one, which the hint carries over as it was written): a
/// hint never leads to a refusal the query didn't have.
@MainActor func expectOfferedAnswered(_ query: String, _ error: QueryError, on h: EditorHarness,
                                      file: StaticString = #fileID, line: UInt = #line) {
    let names: Set<QueryError.Reason> = [.unknownKind, .unknownTitle, .unknownID, .unknownAttribute, .unknownEdgeType, .unknownPseudoClass]
    for offered in offeredQueries(in: error.hint) {
        do {
            guard let again = try refusedAnswer(offered, on: h, file: file, line: line), again.reason != error.reason else { continue }
            let named = again.span.map { String(Array(offered)[$0.offset..<min($0.end, offered.count)]) }
            if names.contains(again.reason), let named, query.contains(named) { continue }
            expect(false, "\(query)'s hint offers \(offered), which is refused: \(again)", file: file, line: line)
        } catch {
            expect(false, "\(offered): \(error)", file: file, line: line)
        }
    }
}

/// The queries a hint offers, as QueryLanguageTests' `offeredQueries` finds them: the hint itself,
/// or a clause of it (between semicolons and sentences' ends) or what follows its last colon, or
/// what comes before "finds", "lists", "is" or "asks" in one of those, less a sentence's end,
/// whichever reads as a query and looks like one (a quote, a bracket, a colon, `#`, `*` or `>`, and
/// no two words in a row; or the whole hint, one word): so a list of words ("Its attributes: a,
/// b"), a sentence ("Did you mean wire or hot-wire?") and a name suggested ("Did you mean
/// "Ledger"?") aren't, though they read.
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

// MARK: Answering queries

/// A query's answer on `h`'s editor (every row by default), the main run loop turned while it runs.
@MainActor func answer(_ text: String, on h: EditorHarness, limit: Int = QueryRequest.every, countOnly: Bool = false,
                       properties: QueryRequest.Properties = .all, file: StaticString = #fileID, line: UInt = #line) throws -> QueryResult {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: limit, countOnly: countOnly, properties: properties))
    }
}

/// The shapes a query matches on `h`'s editor, in the order it lists them.
@MainActor func matched(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> [ShapeID] {
    try answer(text, on: h, properties: .none, file: file, line: line).rows.map(\.id)
}

/// Why `h`'s editor refuses to answer a query; nil if it answers.
@MainActor func refusedAnswer(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> QueryError? {
    do {
        _ = try answer(text, on: h, file: file, line: line)
        return nil
    } catch let error as QueryError {
        return error
    }
}

/// Each query matches the shapes numbered (`id(n)`), in that order.
@MainActor func expectMatches(_ cases: KeyValuePairs<String, [Int]>, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) {
    for (text, numbers) in cases {
        do {
            expectEqual(try matched(text, on: h, file: file, line: line), numbers.map(id), text, file: file, line: line)
        } catch {
            expect(false, "\(text) is refused: \(error)", file: file, line: line)
        }
    }
}

/// Runs this thread for `duration` of its CPU: a record that costs that much to ask.
func burn(_ duration: Duration) {
    let (seconds, attoseconds) = duration.components
    let nanoseconds = UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
    while clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start < nanoseconds {}
}
