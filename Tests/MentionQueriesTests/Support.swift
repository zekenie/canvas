import Adornments
import AppKit
import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Foundation
import Keyboard
import Mentions
import Queries
import QueryLanguage
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology

// Fixtures only, as MentionsTests' mention validation tests keep theirs: scribbles, titled boxes of
// mention text that can be mentioned, and CanvasTesting's pockets (titled and mentionable here,
// whose boards nest) and links, which carry strands, edges that aren't mentions. A fixture names
// shapes for queries by the title Titles keeps: of the plugins that give queries words, only
// `MentionQueriesPlugin` is installed here.

/// A titled box of text that may mention any shape that can be mentioned.
struct Scribble: BoxShapeProps {
    static let kind: ShapeKind = "scribble"
    static let properties = Properties<Scribble> {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame: CGRect
    var text: MentionText
    init(_ frame: CGRect = .zero, text: MentionText = "") {
        self.frame = frame
        self.text = text
    }
}

extension Scribble {
    init() { self.init(.zero) }
}

struct ScribbleDefinition {}

extension ScribbleDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Scribble>, in context: RenderContext) {}
}

/// What a link carries: an edge that isn't a mention.
enum StrandEdge {}

extension StrandEdge: EdgeType {
    static let id: EdgeTypeID = "strand"
}

/// Scribbles, titled and mentionable; pockets titled and mentionable too; links as strands.
struct ScribblesPlugin: CanvasPlugin {
    var id: PluginID { "scribbles" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(ScribbleDefinition()) { scribble in
            scribble.title(contents: false)
            scribble.mentionable()
        }
        registrar.title(Pocket.self, pill: false, contents: false)
        registrar.mentionable(Pocket.self)
        registrar.edgeType(StrandEdge.self)
        registrar.edges(Link.self) { record, _, sink in
            guard let link = record.props as? Link, let from = link.from, let to = link.to else { return }
            sink.emit(StrandEdge.id, from: from, to: to)
        }
    }
}

/// Shapes named for queries by the title Titles keeps.
func namesPlugin() -> Contributor {
    Contributor(id: "names") { registrar in
        registrar.queryNames(attribute: TitleProperty.key.rawValue,
                             source: { kind, registry in registry.properties(for: kind).contains(TitleProperty.key) ? .named : .none },
                             named: { TitleProperty.folded($0[TitleProperty.self]) },
                             derived: { _, _ in nil },
                             fold: { TitleProperty.folded($0) })
    }
}

/// The keyboard, the selection and Topology first, the fixtures, what Mentions builds on and its
/// opt-ins need (the panel, the context menu, titles with their adornments and slash commands),
/// Mentions, Queries and the fixtures' names, then `MentionQueriesPlugin`.
@MainActor func mentionPlugins(withPlugin: Bool = true) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PocketsPlugin(), LinksPlugin(), ScribblesPlugin(),
     AdornmentsPlugin(), DetailPanelPlugin(), ContextMenusPlugin(), SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin(),
     QueriesPlugin(), namesPlugin()] + (withPlugin ? [MentionQueriesPlugin()] : [])
}

func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

let unit = CGRect(x: 0, y: 0, width: 100, height: 60)

func shape<P: ShapeProps>(_ n: Int, _ props: P, titled title: String? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id(n), props))
    record[TitleProperty.self] = title
    return record
}

func scribble(_ n: Int, titled title: String? = nil, _ runs: [MentionRun]) -> AnyShapeRecord {
    shape(n, Scribble(unit, text: MentionText(runs)), titled: title)
}

/// On the top board: scribble 1 "Gateway" mentioning Checkout (by a name it no longer has), 2
/// "Auth" mentioning nothing, pocket 3 "Payments", 4 "Loop" mentioning itself, 5 "Ledger"
/// mentioning shape 99, which isn't in the file, and link 6, a strand from Auth to Gateway. On the
/// pocket's board: scribble 11 "Checkout" mentioning Gateway, and scribble 12, untitled, mentioning
/// Payments. In file order: 1, 2, 3, 11, 12, 4, 5, 6.
func mentionFile() -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: [
        scribble(1, titled: "Gateway", [.text("Owns auth. See "), .mention(id(11), label: "Checkout page")]),
        scribble(2, titled: "Auth", [.text("JWT, 15 min expiry")]),
        shape(3, Pocket(unit), titled: "Payments"),
        scribble(4, titled: "Loop", [.text("Back to "), .mention(id(4), label: "Loop")]),
        scribble(5, titled: "Ledger", [.text("Moved to "), .mention(id(99), label: "Old ledger")]),
        shape(6, Link(from: id(2), to: id(1))),
    ]), children: [id(3): CanvasDocument(shapes: [
        scribble(11, titled: "Checkout", [.text("Calls "), .mention(id(1), label: "Gateway"), .text(" for tokens")]),
        scribble(12, [.text("Retry, see "), .mention(id(3), label: "Payments")]),
    ])])
}

@MainActor func mentionHarness(withPlugin: Bool = true) throws -> EditorHarness {
    try EditorHarness(plugins: mentionPlugins(withPlugin: withPlugin), file: mentionFile())
}

/// A query's answer on `h`'s editor, every row, the main run loop turned while it runs.
@MainActor func answer(_ text: String, on h: EditorHarness, properties: QueryRequest.Properties = .all,
                       file: StaticString = #fileID, line: UInt = #line) throws -> QueryResult {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: QueryBudget.maxRows, properties: properties))
    }
}

/// Why `h`'s editor refuses a query; nil if it answers.
@MainActor func refusal(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> QueryError? {
    do {
        _ = try answer(text, on: h, file: file, line: line)
        return nil
    } catch let error as QueryError {
        return error
    }
}

/// Each query matches the shapes numbered, in that order.
@MainActor func expectMatches(_ cases: KeyValuePairs<String, [Int]>, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) {
    for (text, numbers) in cases {
        do {
            expectEqual(try answer(text, on: h, properties: .none, file: file, line: line).rows.map(\.id), numbers.map(id), text, file: file, line: line)
        } catch {
            expect(false, "\(text) is refused: \(error)", file: file, line: line)
        }
    }
}

/// Each scribble's text as a query's rows show it, by number.
@MainActor func texts(on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> [ShapeID: String] {
    let rows = try answer("scribble", on: h, properties: .only(["text"]), file: file, line: line).rows
    return Dictionary(rows.compactMap { row in row.properties?["text"]?.stringValue.map { (row.id, $0) } }, uniquingKeysWith: { first, _ in first })
}

extension CanvasEditor {
    /// Renames a shape on whatever board it's on, in a transaction of its own.
    func rename(_ id: ShapeID, _ title: String) {
        guard let board = file.board(containing: id) else { return }
        transact(on: board, "Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
    }
}
