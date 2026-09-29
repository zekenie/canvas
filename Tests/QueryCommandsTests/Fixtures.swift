import Automation
import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import Queries
import QueryCommands
import QueryLanguage
import TestKit
import Topology

// Fixtures of QueryCommands' tests' own, over CanvasTesting's chores, pockets and links, never a
// real plugin's: links are wires; a caption names chores and pockets, and an untitled pocket's
// board is an "Untitled Pocket"; the words are :picked (the person's selection, the shapes a test
// picks) and :slow (asked on the main actor, as slowly as a test says); and a scripted model.

// MARK: Plugins

enum WireEdge {}
extension WireEdge: EdgeType {
    static let id: EdgeTypeID = "wire"
    static let summary: String? = "a link, from the shape it starts on to the shape it ends on"
}

/// Wires, which links carry.
func graphPlugin() -> Contributor {
    Contributor(id: "graph") { registrar in
        registrar.edgeType(WireEdge.self)
        registrar.edges(Link.self) { record, _, sink in
            guard let link = record.props as? Link, let from = link.from, let to = link.to else { return }
            sink.emit(WireEdge.id, from: from, to: to)
        }
    }
}

/// What a chore or a pocket is called: nil until one is given.
enum Caption {}
extension Caption: ShapeProperty {
    static let key: PropertyKey = "caption"
    static var defaultValue: String? { nil }
    static func isNone(_ value: String) -> Bool { value.allSatisfy(\.isWhitespace) }
}

/// A caption, folded: one line, trimmed; nil for none.
@Sendable func folded(_ text: String?) -> String? {
    guard let text else { return nil }
    let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    return line.isEmpty ? nil : line
}

/// Captions, which chores and pockets hold, and name them for queries; an untitled pocket's board
/// is an "Untitled Pocket".
func namesPlugin() -> Contributor {
    Contributor(id: "names") { registrar in
        registrar.declare(Caption.self)
        registrar.optIn(Chore.self, to: Caption.self)
        registrar.optIn(Pocket.self, to: Caption.self)
        registrar.queryNames(attribute: Caption.key.rawValue,
                             source: { kind, registry in registry.properties(for: kind).contains(Caption.key) ? .named : .none },
                             named: { folded($0[Caption.self]) },
                             derived: { _, _ in nil },
                             fold: { folded($0) })
        registrar.queryBoardNames { kind, _ in kind == Pocket.kind ? "Untitled Pocket" : nil }
    }
}

/// What the person has picked (`:picked`, the selection word), and how slowly `:slow` answers.
@MainActor final class Desk {
    var picked: [ShapeID] = []
    /// What saying what's picked does, each time it's asked.
    var onPicked: (() -> Void)?
    /// How many times `:slow` was asked, and what it does each time.
    var slowCalls = 0
    var onSlow: (() -> Void)?
}

/// `:picked`, the person's selection (`desk.picked`), and `:slow`, true of every chore, asked on
/// the main actor.
func wordsPlugin(_ desk: Desk) -> Contributor {
    Contributor(id: "words") { registrar in
        registrar.querySelection("picked", "the person picked it", example: ":picked", selected: { _ in
            desk.onPicked?()
            return desk.picked
        })
        registrar.queryPseudoClass("slow", "it takes a while to say", example: ":slow", prepare: { _ in () },
                                   matches: { shape, _ in shape.record.kind == Chore.kind ? .onMain : .no },
                                   onMain: { _, _, _, _ in
                                       desk.slowCalls += 1
                                       desk.onSlow?()
                                       return true
                                   })
    }
}

let systemPrompt = "You write one query."

/// The fixtures, Topology, Automation, Queries and its commands, and `model` if one: every point
/// filled. Without Queries, nothing that fills its points.
@MainActor func commandPlugins(model: ScriptedLanguageModel? = ScriptedLanguageModel(), queries: Bool = true, desk: Desk = Desk(),
                               askStyle: AskStyle = .shipped) -> [any CanvasPlugin] {
    var plugins: [any CanvasPlugin] = [ChoresPlugin(), PocketsPlugin(), LinksPlugin(), TopologyPlugin(), AutomationPlugin()]
    if queries { plugins.append(QueriesPlugin()) }
    if let model { plugins.append(LanguageModelsPlugin(model: model)) }
    plugins += [QueryCommandsPlugin(askPrompt: systemPrompt, askStyle: askStyle), graphPlugin()]
    if queries { plugins += [namesPlugin(), wordsPlugin(desk)] }
    return plugins
}

// MARK: The file

let unit = CGRect(x: 0, y: 0, width: 100, height: 60)

func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

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

func link(_ id: ShapeID, _ from: ShapeID, _ to: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to))) }

/// A note longer than a row lists whole: 600 characters.
let longNote = String(repeating: "ab", count: 300)

/// On the top board, chore 1 "Alpha" (a long note), pocket 2 "Pantry" and link 3 from 1 to 2; on
/// the pantry's board, chore 11 "Beta" and pocket 12, untitled; on its board, chore 21, untitled,
/// and chore 22 "Gamma", done.
func shelf() -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: [chore(id(1), caption: "Alpha", Chore(unit, note: longNote)), pocket(id(2), caption: "Pantry"),
                                             link(id(3), id(1), id(2))]),
               children: [id(2): CanvasDocument(shapes: [chore(id(11), caption: "Beta"), pocket(id(12))]),
                          id(12): CanvasDocument(shapes: [chore(id(21)), chore(id(22), caption: "Gamma", Chore(unit, status: .done))])])
}

@MainActor func shelfHarness(_ plugins: [any CanvasPlugin] = commandPlugins(), file: CanvasFile = shelf()) throws -> EditorHarness {
    try EditorHarness(plugins: plugins, file: file)
}

// MARK: Running commands

/// A command running, and what it answered once it's done.
@MainActor final class Pending {
    var result: Result<JSON, RPCError>?
    var task: Task<Void, Never>?
}

/// Starts a command, as the command line spells it, on `h`'s board (none for an app command) as the
/// app's server runs it; `input` is its standard input.
@MainActor func start(_ line: [String], on h: EditorHarness, input: String = "") throws -> Pending {
    let registry = h.editor.registry
    let spec = try require(registry.automationCommands.first { $0.name == line[0] })
    let params = try spec.params(from: Array(line.dropFirst()), standardInput: { input })
    let editor = spec.scope == .board ? h.editor : nil
    let pending = Pending()
    pending.task = Task { @MainActor in
        do throws(RPCError) {
            pending.result = .success(try await registry.runAutomationCommand(spec.name, params: .object(params), editor: editor))
        } catch {
            pending.result = .failure(error)
        }
    }
    return pending
}

/// What a command started answered, the main run loop turned until it has.
@MainActor func finish(_ pending: Pending, file: StaticString = #fileID, line: UInt = #line) throws -> Result<JSON, RPCError> {
    guard spinRunLoop(until: { pending.result != nil }, timeout: 5, file: file, line: line), let result = pending.result else { throw RequireFailed() }
    return result
}

/// A command's answer, run to its end.
@MainActor func run(_ line: [String], on h: EditorHarness, input: String = "", file: StaticString = #fileID, line number: UInt = #line) throws -> Result<JSON, RPCError> {
    try finish(start(line, on: h, input: input), file: file, line: number)
}

/// A command's answer, which must be one.
@MainActor func answered(_ line: [String], on h: EditorHarness, input: String = "", file: StaticString = #fileID, line number: UInt = #line) throws -> JSON {
    switch try run(line, on: h, input: input, file: file, line: number) {
    case .success(let json): return json
    case .failure(let error):
        expect(false, "\(line) is refused: \(error.reason ?? "") \(error.message)", file: file, line: number)
        throw error
    }
}

/// Why a command was refused, which it must be.
@MainActor func refused(_ result: Result<JSON, RPCError>, file: StaticString = #fileID, line: UInt = #line) throws -> RPCError {
    switch result {
    case .success(let json):
        expect(false, "answered \(json)", file: file, line: line)
        throw RequireFailed()
    case .failure(let error): return error
    }
}

@MainActor func refused(_ line: [String], on h: EditorHarness, input: String = "", file: StaticString = #fileID, line number: UInt = #line) throws -> RPCError {
    try refused(run(line, on: h, input: input, file: file, line: number), file: file, line: number)
}

/// The ids of an answer's rows, in order.
func rowIDs(_ json: JSON) -> [String] {
    json["rows"]?.arrayValue?.compactMap { $0["id"]?.stringValue } ?? []
}

/// Why `h`'s editor refuses a query, as the engine says it; nil if it resolves.
@MainActor func checked(_ text: String, on h: EditorHarness) -> QueryError? {
    guard let queries = h.editor.queries else { return nil }
    do throws(QueryError) {
        _ = try queries.check(text)
        return nil
    } catch {
        return error
    }
}

/// A query's answer on `h`'s editor, as the engine gives it.
@MainActor func result(_ text: String, on h: EditorHarness, limit: Int = QueryBudget.rows, countOnly: Bool = false,
                       properties: QueryRequest.Properties = .all, file: StaticString = #fileID, line: UInt = #line) throws -> QueryResult {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: limit, countOnly: countOnly, properties: properties))
    }
}
