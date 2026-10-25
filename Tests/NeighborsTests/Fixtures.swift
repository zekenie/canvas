import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import DetailPanel
import Foundation
import Keyboard
import Neighbors
import Queries
import Selection
import TableOfContents
import TestKit
import Topology

// Fixtures of Neighbors' own, over CanvasTesting's kinds, never a real plugin's: links are wires, a
// memo's lead is quoted (what a mention is), a pill stands for the shapes it cites (what a reference
// does), pockets own boards and corrals hold shapes. Four lights of the tests' own ask for them, in
// pure colors, by the edge types' ids: what a shape has a wire to (the links that start at it, and,
// for a link, where it ends), what has a wire to it (and, for a link, where it starts), what it
// quotes, what quotes it.

enum WireEdge {}
extension WireEdge: EdgeType {
    static let id: EdgeTypeID = "wire"
}

enum QuoteEdge {}
extension QuoteEdge: EdgeType {
    static let id: EdgeTypeID = "quote"
}

/// A box that stands for the shapes it cites, as a reference stands for a shape.
struct Pill: BoxShapeProps {
    static let kind: ShapeKind = "pill"
    static let properties = Properties<Pill> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
    }
    var frame: CGRect
    var stands: [Citation]
    init(_ frame: CGRect, stands: [Citation] = []) {
        self.frame = frame
        self.stands = stands
    }
}

extension Pill {
    init() { self.init(.zero) }
}

struct PillDefinition {}

extension PillDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Pill>, in context: RenderContext) {}
}

/// A box that stands for whatever is provided for the question it asks (`topology.provide`), nothing
/// until an answer comes.
struct Lens: BoxShapeProps {
    static let kind: ShapeKind = "lens"
    static let properties = Properties<Lens> {
        Property("frame", \.frame).required()
        Property("asks", \.asks)
    }
    var frame: CGRect
    var asks: String
    init(_ frame: CGRect, asks: String = "") {
        self.frame = frame
        self.asks = asks
    }
}

extension Lens {
    init() { self.init(.zero) }
}

struct LensDefinition {}

extension LensDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lens>, in context: RenderContext) {}
}

/// The fixtures' edges: a link bound at both ends is a wire, a memo's lead (and what else its props
/// name) a quote, what a pill cites it stands for, and what's provided for a lens is what it stands for.
func graphPlugin() -> Contributor {
    Contributor(id: "graph") { registrar in
        registrar.edgeType(WireEdge.self)
        registrar.edgeType(QuoteEdge.self)
        registrar.edges(Link.self) { record, _, sink in
            guard let link = record.props as? Link, let from = link.from, let to = link.to else { return }
            sink.emit(WireEdge.id, from: from, to: to)
        }
        registrar.edges(Memo.self) { record, registry, sink in
            record.forEachNamingValue(in: registry) { property, value in
                guard property != CitationsProperty.key.rawValue else { return }
                value.forEachNamedShape { sink.emit(QuoteEdge.id, from: record.id, to: $0, slot: property) }
            }
        }
        registrar.shape(PillDefinition()) { pill in
            pill.standsIn { shape, _ in shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape)) }
        }
        registrar.shape(LensDefinition()) { lens in
            lens.standsIn { shape, _ in shape.props.asks.isEmpty ? nil : .provided(ForwardingKey(shape.props.asks)) }
        }
    }
}

/// The four lights, each in a color a pixel could tell: green, red, cyan, magenta.
enum Light: Int, CaseIterable {
    case out, into, quotes, quoted

    var color: NSColor {
        switch self {
        case .out: NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        case .into: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        case .quotes: NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1)
        case .quoted: NSColor(srgbRed: 1, green: 0, blue: 1, alpha: 1)
        }
    }

    init?(color: NSColor) {
        guard let light = Light.allCases.first(where: { $0.color == color }) else { return nil }
        self = light
    }
}

/// The lights, as the shipped ones are written: a query for the shape named `#id`, and, for an arrow
/// (a link) hovered, where it ends and starts; between a shape and what it's wired to, the links; and
/// under a shape that quotes the subject, a caption saying so.
func testLights() -> [NeighborLight] {
    let wire = WireEdge.id.rawValue, standing = StandingEdge.id.rawValue, quote = QuoteEdge.id.rawValue
    return [
        NeighborLight("Wired To", color: Light.out.color, query: { ":edge-from(\($0), \(wire)|\(standing)), :end-of(\($0), \(wire))" },
                      between: { ":starts-at(\($0), \(wire))" }),
        NeighborLight("Wired From", color: Light.into.color, query: { ":edge-to(\($0), \(wire)|\(standing)), :start-of(\($0), \(wire))" },
                      between: { ":ends-at(\($0), \(wire))" }),
        NeighborLight("Quotes", color: Light.quotes.color, query: { ":edge-from(\($0), \(quote))" }),
        NeighborLight("Quoted By", color: Light.quoted.color, query: { ":edge-to(\($0), \(quote))" },
                      caption: { editor, subject, neighbor in
                          editor.shape(inFile: neighbor)?[Caption.self].map { "\($0) quotes \(subject.description.prefix(4))" }
                      }),
    ]
}

/// The same lights shown by the keys the shipped ones are: what it has a wire to on a plain hover, what
/// has a wire to it with ⌥, and its quotes both ways with ⌃⌥.
func keyedLights() -> [NeighborLight] {
    let keys: [Modifiers] = [[], .option, [.control, .option], [.control, .option]]
    return zip(testLights(), keys).map { light, keys in
        var light = light
        light.keys = keys
        return light
    }
}

/// A plugin that gives Neighbors `lights`, in order, as the plugins that own the edges give theirs.
func lightsPlugin(_ lights: [NeighborLight]) -> Contributor {
    Contributor(id: "lights") { registrar in
        for light in lights {
            registrar.neighborLight(light.title, color: light.color, keys: light.keys, query: light.query, between: light.between,
                                    caption: light.caption)
        }
    }
}

/// What a fixture shape is called: nil until one is given.
enum Caption {}
extension Caption: ShapeProperty {
    static let key: PropertyKey = "caption"
    static var defaultValue: String? { nil }
    static func isNone(_ value: String) -> Bool { value.allSatisfy(\.isWhitespace) }
}

/// Captions, which every fixture kind here holds, and which name shapes for queries, so a row of the
/// engine's has a title.
func namesPlugin() -> Contributor {
    Contributor(id: "names") { registrar in
        registrar.declare(Caption.self)
        registrar.optInEveryShape(to: Caption.self, where: { _ in true })
        registrar.queryNames(attribute: Caption.key.rawValue,
                             source: { _, _ in .named },
                             named: { $0[Caption.self].flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 } },
                             derived: { _, _ in nil },
                             fold: { $0.allSatisfy(\.isWhitespace) ? nil : $0 })
    }
}

/// An editor of `file` with the keyboard and the selection (a hover), Topology, the fixtures and the
/// engine, then Neighbors and a plugin that gives it `lights`.
@MainActor func neighborHarness(_ file: CanvasFile, lights: [NeighborLight] = testLights(), queries: Bool = true,
                                  more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), LinksPlugin(), PocketsPlugin(), CorralsPlugin(),
                                NamingPlugin(), graphPlugin()] + (queries ? [QueriesPlugin()] : []) + [NeighborsPlugin(), lightsPlugin(lights)], file: file)
}

/// The same editor with the detail panel, the lists of what's connected to a shape in it
/// (`NeighborDetailsPlugin`), the table of contents, where a memo's row is its text, and, with the
/// engine, captions that name its shapes in the engine's rows.
@MainActor func listHarness(_ file: CanvasFile, lights: [NeighborLight] = testLights(), queries: Bool = true,
                                  more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), LinksPlugin(), PocketsPlugin(), CorralsPlugin(),
                                NamingPlugin(), graphPlugin(), DetailPanelPlugin(), TableOfContentsPlugin(), memoRowsPlugin()]
                          + (queries ? [QueriesPlugin(), namesPlugin()] : [])
                          + [NeighborsPlugin(), lightsPlugin(lights), NeighborDetailsPlugin()] + more, file: file)
}


// MARK: Records

let unit = CGRect(x: 0, y: 0, width: 100, height: 60)

func box(_ id: ShapeID, at origin: CGPoint = .zero) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Box(unit.offsetBy(dx: origin.x, dy: origin.y)))) }
func pocket(_ id: ShapeID, at origin: CGPoint = .zero) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Pocket(unit.offsetBy(dx: origin.x, dy: origin.y)))) }
func corral(_ id: ShapeID) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Corral(CGRect(x: 0, y: 0, width: 400, height: 300)))) }
func link(_ id: ShapeID, _ from: ShapeID?, _ to: ShapeID?) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, Link(from: from, to: to))) }
func memo(_ id: ShapeID, quoting lead: ShapeID? = nil, at origin: CGPoint = .zero) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Memo(unit.offsetBy(dx: origin.x, dy: origin.y), lead: lead.map(Citation.init))))
}
func pill(_ id: ShapeID, standingFor stands: [ShapeID], at origin: CGPoint = .zero) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Pill(unit.offsetBy(dx: origin.x, dy: origin.y), stands: stands.map(Citation.init))))
}
func lens(_ id: ShapeID, asks: String, at origin: CGPoint = .zero) -> AnyShapeRecord {
    AnyShapeRecord(ShapeRecord(id: id, Lens(unit.offsetBy(dx: origin.x, dy: origin.y), asks: asks)))
}
func board(_ records: AnyShapeRecord...) -> CanvasDocument { CanvasDocument(shapes: records) }

/// The record, in `container` on its board.
func held(_ record: AnyShapeRecord, in container: ShapeID) -> AnyShapeRecord { record.copy(as: record.id, container: container) }

// MARK: Reading what's lit

/// One group the canvas outlines: the light it's in, its ring and its shapes.
struct Lit: Equatable, CustomStringConvertible {
    let light: Light
    let ring: Int
    let shapes: Set<ShapeID>

    init(_ light: Light, _ ring: Int, _ shapes: Set<ShapeID>) {
        self.light = light
        self.ring = ring
        self.shapes = shapes
    }

    var description: String { "\(light) ring \(ring): \(shapes.map { String($0.description.prefix(4)) }.sorted())" }
}

/// Counts what the editor tells its view: how many times it's asked to draw. (Its delegate protocol
/// is the host's, so it can't be public in CanvasTesting.)
@MainActor final class Redraws: CanvasEditorDelegate {
    var count = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { count += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}

extension EditorHarness {
    var neighbors: NeighborState { editor.neighbors! }

    /// Lets the look at the hover happen (a turn of the scheduler) and its answer land: the main run
    /// loop turns until nothing is asked.
    func settle(file: StaticString = #fileID, line: UInt = #line) {
        wait(0)
        spinRunLoop(until: { !neighbors.isAsking }, file: file, line: line)
    }

    /// What the canvas outlines in the lights' colors now, in the order the core strokes the groups.
    var lit: [Lit] {
        editor.outlines.tinted.map { Lit(Light(color: $0.color)!, $0.ring, Set($0.shapes)) }
    }

    /// What the canvas outlines faintly.
    var faint: [ShapeID] { editor.outlines.faintShapes }
}
