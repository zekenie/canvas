import Adornments
import AppKit
import Boards
import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import Foundation
import Keyboard
import Queries
import QueryLexicon
import Selection
import SlashCommands
import TestKit
import Titles
import Topology

// Fixtures only: CanvasTesting's boxes and two kinds of this target's that own boards, drawers,
// which open onto them with a placeholder of their own, and crates, which don't open (so have no
// placeholder) and are called by their label. Both are named by Titles, and a fixture names shapes
// for queries by the title Titles keeps: of QueryLexicon's plugins, only `BoardQueriesPlugin` is
// installed here.

/// A box that owns a board and opens onto it, called "Untitled Drawer" while untitled.
struct Drawer: BoxShapeProps {
    static let kind: ShapeKind = "drawer"
    static let properties = Properties<Drawer> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Drawer {
    init() { self.init(.zero) }
}

struct DrawerDefinition {}

extension DrawerDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Drawer>, in context: RenderContext) {}
}

extension DrawerDefinition: BoardOwning {}

/// A box that owns a board it doesn't open onto: its kind is called "Crate".
struct Crate: BoxShapeProps {
    static let kind: ShapeKind = "crate"
    static let properties = Properties<Crate> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Crate {
    init() { self.init(.zero) }
}

struct CrateDefinition {}

extension CrateDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Crate>, in context: RenderContext) {}
}

extension CrateDefinition: BoardOwning {}

/// Drawers and crates, both titled.
struct StorePlugin: CanvasPlugin {
    var id: PluginID { "store" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(DrawerDefinition()) { drawer in
            drawer.title(pill: false, contents: false)
            drawer.opensBoard(placeholder: "Untitled Drawer", systemImage: "archivebox")
        }
        registrar.shape(CrateDefinition()) { crate in
            crate.title(pill: false, contents: false)
            crate.label("Crate", systemImage: "shippingbox")
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

/// What opening a board takes (keys, the selection, the panel, menus), titles (with the adornments
/// their pills are, and the slash commands they offer), Topology, Boards, Queries and the fixtures'
/// names, then `BoardQueriesPlugin`.
@MainActor func boardPlugins(withPlugin: Bool = true) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), StorePlugin(), DetailPanelPlugin(), ContextMenusPlugin(),
     AdornmentsPlugin(), SlashCommandsPlugin(), TitlesPlugin(), BoardsPlugin(), QueriesPlugin(), namesPlugin()] + (withPlugin ? [BoardQueriesPlugin()] : [])
}

func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

let unit = CGRect(x: 0, y: 0, width: 100, height: 60)

func shape<P: ShapeProps>(_ n: Int, _ props: P, titled title: String? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id(n), props))
    record[TitleProperty.self] = title
    return record
}

/// On the top board, drawer 1 "Kitchen" and box 2; on the kitchen's board, drawer 11, untitled, and
/// box 12; on that drawer's board, crate 21, untitled, and box 22; on the crate's, box 31.
func storeFile() -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: [shape(1, Drawer(unit), titled: "Kitchen"), shape(2, Box(unit))]),
               children: [id(1): CanvasDocument(shapes: [shape(11, Drawer(unit)), shape(12, Box(unit))]),
                          id(11): CanvasDocument(shapes: [shape(21, Crate(unit)), shape(22, Box(unit))]),
                          id(21): CanvasDocument(shapes: [shape(31, Box(unit))])])
}

@MainActor func storeHarness(withPlugin: Bool = true) throws -> EditorHarness {
    try EditorHarness(plugins: boardPlugins(withPlugin: withPlugin), file: storeFile())
}

/// The record, in `container` on its board.
func held(_ record: AnyShapeRecord, in container: Int) -> AnyShapeRecord { record.copy(as: record.id, container: id(container)) }

/// Containers on boards (CanvasTesting's corrals, titled, which own no board): on the top board,
/// corral 40, untitled, holding drawer 41 "Cellar", and box 42 in nothing; on the cellar's board,
/// corral 50 "Rack" holding box 51 and drawer 52, untitled, whose board holds box 61.
func cellarFile() -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: [shape(40, Corral(unit)), held(shape(41, Drawer(unit), titled: "Cellar"), in: 40), shape(42, Box(unit))]),
               children: [id(41): CanvasDocument(shapes: [shape(50, Corral(unit), titled: "Rack"), held(shape(51, Box(unit)), in: 50),
                                                          held(shape(52, Drawer(unit)), in: 50)]),
                          id(52): CanvasDocument(shapes: [shape(61, Box(unit))])])
}

@MainActor func cellarHarness() throws -> EditorHarness {
    let corrals = Contributor(id: "corral-titles") { $0.title(Corral.self, pill: false, contents: false) }
    return try EditorHarness(plugins: boardPlugins() + [CorralsPlugin(), corrals], file: cellarFile())
}

/// A query's rows on `h`'s editor, every one, the main run loop turned while it runs.
@MainActor func rows(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> [QueryRow] {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: QueryBudget.maxRows, properties: .none))
    }.rows
}

/// What each row says it's inside, by the row's shape's number.
@MainActor func inside(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> [ShapeID: [String]] {
    Dictionary(try rows(text, on: h, file: file, line: line).map { ($0.id, $0.inside) }, uniquingKeysWith: { first, _ in first })
}

/// What the path calls each board a shape is inside, outermost first: Boards' names.
@MainActor func pathNames(of shape: ShapeID, in h: EditorHarness) -> [String] {
    var boards: [BoardID] = []
    var board = h.editor.file.board(containing: shape)
    while let current = board, let owner = current.owner {
        boards.insert(current, at: 0)
        board = h.editor.file.board(containing: owner)
    }
    return boards.map { h.editor.name(of: $0, root: "Top") }
}

extension CanvasEditor {
    func rename(_ id: ShapeID, _ title: String?, on board: BoardID) {
        transact(on: board, "Rename") { $0.update(id) { $0[TitleProperty.self] = title } }
    }
}
