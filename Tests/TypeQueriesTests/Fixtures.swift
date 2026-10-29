import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Queries
import QueryLanguage
import Keyboard
import LanguageModels
import Mentions
import ProseMaps
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology
import Types
import Validation

// Fixtures only, as TypeNamesTests keep theirs: a memo, a box of words that is titled, can be a type and be an instance of one
// (`canBeType()`, `typeable()`) as a note is, a slab, titled and nothing else, and a plain pocket's
// worth of nothing. Types' query words know no kind.

struct Memo: BoxShapeProps {
    static let kind: ShapeKind = "memo"
    static let properties = Properties<Memo>(title: "Memo") {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame: CGRect
    var text: MentionText
    init(frame: CGRect = CGRect(x: 0, y: 0, width: 240, height: 52), text: MentionText = "") {
        self.frame = frame
        self.text = text
    }
    init() { self.init(text: "") }
}

@MainActor
struct MemoDefinition: ShapeDefinition {
    static let style = MentionTextStyle(font: .systemFont(ofSize: 16), color: .black, lineHeight: 19)
    static func placement(_ shape: ShapeRecord<Memo>) -> MentionTextPlacement {
        MentionTextPlacement(shape.props.text, in: shape.frame.insetBy(dx: 16, dy: 16), style: style)
    }
    func render(_ shape: ShapeRecord<Memo>, in context: RenderContext) {
        context.drawMentionText(Self.placement(shape))
    }
}

/// Titled, and nothing else: it is no type and no instance.
struct Slab: BoxShapeProps {
    static let kind: ShapeKind = "slab"
    static let properties = Properties<Slab> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 60)) { self.frame = frame }
    init() { self.init(CGRect(x: 0, y: 0, width: 100, height: 60)) }
}

struct SlabDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Slab>, in context: RenderContext) {}
}

struct MemosPlugin: CanvasPlugin {
    var id: PluginID { "memos" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(MemoDefinition()) { memo in
            memo.tool(label: "Memo", systemImage: "note.text", placing: memo.placement(size: CGSize(width: 240, height: 52)) { Memo() })
            memo.title()
            memo.mentionText { [MemoDefinition.placement($0)] }
            memo.mentionable(untitled: { $0.props.text.firstLine })
            memo.typeWords(\.text, drawnIn: { MemoDefinition.placement($0) })
            memo.canBeType()
            memo.typeable()
        }
        registrar.shape(SlabDefinition()) { slab in
            slab.tool(label: "Slab", systemImage: "square", placing: slab.placement(size: CGSize(width: 100, height: 60)) { Slab() })
            slab.title()
        }
    }
}


func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

/// A memo numbered `n`, titled `title` if given, a type (a schema) or not, and the types it is.
func memo(_ n: Int, _ title: String?, type: Bool = false, is types: [Int] = [], at y: CGFloat = 0) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id(n), Memo(frame: CGRect(x: 40, y: y + 80 * CGFloat(n), width: 240, height: 52))))
    record[TitleProperty.self] = title
    if type { record[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter) }
    if !types.isEmpty { record[IsAProperty.self] = types.map { TypeLink(id($0)) } }
    return record
}

/// The plugins a type needs and the query words: Memos, Types and what it stands on, Queries, titles
/// for names, and the type words.
@MainActor func typeQueryPlugins(typeWords: Bool = true) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), MemosPlugin(), ValidationPlugin(), AdornmentsPlugin(), DetailPanelPlugin(),
     ContextMenusPlugin(), SlashCommandsPlugin(), TableOfContentsPlugin(), TitlesPlugin(), MentionsPlugin(), TypesPlugin(),
     TypeValidationPlugin(), TypeDetailsPlugin(), ValidationDetailsPlugin(), LanguageModelsPlugin(model: ScriptedLanguageModel()), ProseMapsPlugin(),
     QueriesPlugin(), TitleQueriesPlugin()] + (typeWords ? [TypeQueriesPlugin()] : [])
}

/// Person 1 and Employee card 2 (a Person), Ann 3 (an Employee card), Bob 4 (a Person), Cy 5 (a
/// Person and an Employee card), Dot 6 (no type), Alpha 7 and Beta 8, two types each the other's,
/// Eve 9 (an Alpha), and Plain 10, a memo that is no type.
@MainActor func typeHarness(typeWords: Bool = true) throws -> EditorHarness {
    let shapes = [memo(1, "Person", type: true), memo(2, "Employee card", type: true, is: [1]), memo(3, "Ann", is: [2]), memo(4, "Bob", is: [1]),
                  memo(5, "Cy", is: [1, 2]), memo(6, "Dot"), memo(7, "Alpha", type: true, is: [8]), memo(8, "Beta", type: true, is: [7]),
                  memo(9, "Eve", is: [7]), memo(10, "Plain")]
    return try EditorHarness(plugins: typeQueryPlugins(typeWords: typeWords), document: CanvasDocument(shapes: shapes))
}

/// A query's answer on `h`'s editor, every row, the main run loop turned while it runs.
@MainActor func answer(_ text: String, on h: EditorHarness, properties: QueryRequest.Properties = .all,
                       file: StaticString = #fileID, line: UInt = #line) throws -> QueryResult {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: QueryRequest.every, properties: properties))
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
