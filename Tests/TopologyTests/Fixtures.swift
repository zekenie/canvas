@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Topology

// Edge types and sources over CanvasTesting's kinds, never a real plugin's: a link bound at both
// ends is a wire; a citing tag's target a hot wire (a kind of wire); a tag's target a tether, a type
// nobody declares; what a memo's own props name are quotes, in the slot of the property they're in;
// and what its citations name are cites (the property rule).

enum WireEdge {}
extension WireEdge: EdgeType {
    static let id: EdgeTypeID = "wire"
}

enum HotWireEdge {}
extension HotWireEdge: EdgeType {
    static let id: EdgeTypeID = "hot-wire"
    static var parent: EdgeTypeID? { WireEdge.id }
}

enum QuoteEdge {}
extension QuoteEdge: EdgeType {
    static let id: EdgeTypeID = "quote"
}

enum CiteEdge {}
extension CiteEdge: EdgeType {
    static let id: EdgeTypeID = "cite"
}

/// Emitted by tags, and declared by no plugin.
let tether: EdgeTypeID = "tether"

/// The fixtures' edge types and sources.
struct GraphPlugin: CanvasPlugin {
    var id: PluginID { "graph" }

    func register(into registrar: inout PluginRegistrar) {
        registrar.edgeType(WireEdge.self)
        registrar.edgeType(HotWireEdge.self)
        registrar.edgeType(QuoteEdge.self)
        registrar.edgeType(CiteEdge.self)
        registrar.edges(Link.self) { record, _, sink in
            guard let link = record.props as? Link, let from = link.from, let to = link.to else { return }
            sink.emit(WireEdge.id, from: from, to: to)
        }
        registrar.edges(CitingTag.self) { record, _, sink in
            guard let target = (record.props as? CitingTag)?.target else { return }
            sink.emit(HotWireEdge.id, from: record.id, to: target)
        }
        registrar.edges(Tag.self) { record, _, sink in
            guard let target = (record.props as? Tag)?.target else { return }
            sink.emit(tether, from: record.id, to: target)
        }
        registrar.edges(Memo.self) { record, registry, sink in
            record.forEachNamingValue(in: registry) { property, value in
                guard property != CitationsProperty.key.rawValue else { return }
                value.forEachNamedShape { sink.emit(QuoteEdge.id, from: record.id, to: $0, slot: property) }
            }
        }
        registrar.edges(in: CitationsProperty.self, as: CiteEdge.self)
    }
}

let unit = CGRect(x: 0, y: 0, width: 100, height: 100)

func box(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(unit))) }
func pocket(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(unit))) }
func link(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to))) }
func memo(_ id: ShapeID, notes: [MemoNote] = [], lead: ShapeID? = nil) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Memo(unit, notes: notes, lead: lead.map(Citation.init))))
}
func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }
func corral(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Corral(unit))) }

/// The record, in `container` on its board: what a board read from a file holds.
func held(_ record: AnyShapeRecord, in container: ShapeID) -> AnyShapeRecord { record.copy(as: record.id, container: container) }

/// The fixtures' plugins with Topology's: `first` before them all (a service made before the
/// index's), `more` after.
@MainActor func graphPlugins(first: [any CanvasPlugin] = [], more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    first + [FixturesPlugin(), LinksPlugin(), NamingPlugin(), PocketsPlugin(), TopologyPlugin(), GraphPlugin()] + more
}

@MainActor func graph(_ file: CanvasFile = CanvasFile(), first: [any CanvasPlugin] = [], more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: graphPlugins(first: first, more: more), file: file)
}

extension EditorHarness {
    var topology: TopologyIndex { editor.topology! }
}

/// An edge as the fixtures carry it, once.
func edge(_ type: EdgeTypeID, _ source: ShapeID, _ target: ShapeID, by carrier: ShapeID, slot: String = "", count: Int = 1) -> Edge {
    Edge(type: type, source: source, target: target, carrier: carrier, slot: slot, count: count)
}

/// A root holding boxes A and B, link L from A to B, and pocket P; P's board holds box C, link M
/// from C to A (across boards) and pocket Q; Q's holds box D and link N from D to C.
struct Nest {
    let a = ShapeID(), b = ShapeID(), l = ShapeID(), p = ShapeID(), c = ShapeID(), m = ShapeID(), q = ShapeID(), d = ShapeID(), n = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: board(box(a), box(b), link(l, a, b), pocket(p)),
                   children: [p: board(box(c), link(m, c, a), pocket(q)), q: board(box(d), link(n, d, c))])
    }
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }
}

/// Containers and boards, one tree: on the root, corral F holding box A, corral G (holding box B) and
/// pocket P, then box E and link L from A to C, in nothing; P's board holds corral R, holding box C
/// and pocket Q, and box D in nothing; Q's board holds box K.
struct Pen {
    let f = ShapeID(), a = ShapeID(), g = ShapeID(), b = ShapeID(), p = ShapeID(), e = ShapeID(), l = ShapeID()
    let r = ShapeID(), d = ShapeID(), c = ShapeID(), q = ShapeID(), k = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: board(corral(f), held(box(a), in: f), held(corral(g), in: f), held(box(b), in: g), held(pocket(p), in: f), box(e),
                               link(l, a, c)),
                   children: [p: board(corral(r), box(d), held(box(c), in: r), held(pocket(q), in: r)), q: board(box(k))])
    }
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }
    /// Every shape, in file order.
    var fileOrder: [ShapeID] { [f, a, g, b, p, r, c, q, k, d, e, l] }
}

func uuid(_ n: Int) -> String { String(format: "00000000-0000-0000-0000-%012d", n) }
func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

/// A file read from a board file: on the root, box 1, link 2 from 1 to 3, and a gadget 10 (a kind
/// nobody installs, kept aside) whose board, which the app can't show, holds box 11, box 12 and link
/// 13 from 11 to 12, and link 14 from 11 to box 1 on the root.
@MainActor func hiddenFile() throws -> LoadedBoard {
    func frame() -> String { "\"frame\" : [[0, 0], [1, 1]]" }
    let json = """
    { "format" : 4, "versions" : { "kinds" : { "box" : 0, "link" : 0 } },
      "shapes" : [ { "id" : "\(uuid(1))", "kind" : "box", "index" : "a0", "props" : { \(frame()) } },
                   { "id" : "\(uuid(2))", "kind" : "link", "index" : "a1", "props" : { "from" : "\(uuid(1))", "to" : "\(uuid(3))" } },
                   { "id" : "\(uuid(10))", "kind" : "gadget", "index" : "a2", "props" : { } } ],
      "boards" : {
        "\(uuid(10))" : { "shapes" : [ { "id" : "\(uuid(11))", "kind" : "box", "index" : "a0", "props" : { \(frame()) } },
                                        { "id" : "\(uuid(12))", "kind" : "box", "index" : "a1", "props" : { \(frame()) } },
                                        { "id" : "\(uuid(13))", "kind" : "link", "index" : "a2", "props" : { "from" : "\(uuid(11))", "to" : "\(uuid(12))" } },
                                        { "id" : "\(uuid(14))", "kind" : "link", "index" : "a3", "props" : { "from" : "\(uuid(11))", "to" : "\(uuid(1))" } } ] }
      } }
    """
    return try BoardCodec(registry: Registry(plugins: graphPlugins())).decode(Data(json.utf8))
}

/// A source that reads nothing of a disc but its id (each disc is a wire to itself), so what keeps a
/// disc kept aside from carrying one is the index's guard, not a cast of its props that fails.
@MainActor func signalsPlugin() -> Contributor {
    Contributor(id: "signals") { registrar in
        registrar.edges(Disc.self) { record, _, sink in sink.emit(WireEdge.id, from: record.id, to: record.id) }
    }
}

/// A file whose discs are of a version newer than the fixtures' (so kept aside): disc 20 on the root.
@MainActor func newerDiscsFile() throws -> LoadedBoard {
    let json = """
    { "format" : 1, "schema" : { "disc" : 99 },
      "shapes" : [ { "id" : "\(uuid(20))", "kind" : "disc", "index" : "a0", "props" : { "frame" : [[0, 0], [1, 1]] } } ] }
    """
    return try BoardCodec(registry: Registry(plugins: graphPlugins(more: [signalsPlugin()]))).decode(Data(json.utf8))
}
