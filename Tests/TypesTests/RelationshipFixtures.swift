import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Draw
import Foundation
import Mentions
import TestKit
import Titles
import Validation
import Topology
import Types

// Types names no kind, so the tests of relationships carry the kinds Types never sees: a bond, an arrow of
// the tests' own (words, two bindings, an edge in the empty slot of a family of its own, an instance of
// types that relates), a filler of Draw's edges that makes bonds, and a relay, a pill that stands for the
// shapes it cites, but only open ones.

enum BondEdge {}

extension BondEdge: EdgeType {
    static let id: EdgeTypeID = "bond-edge"
    static let summary: String? = "a bond, from the shape it starts on to the shape it ends on"
}

/// An arrow, as far as relationships go: words, two bindings (nil: free), heads it has none of.
struct Bond: ShapeProps {
    static let kind: ShapeKind = "bond"
    static let properties = Properties<Bond>(title: "Bond") {
        Property("from", \.from)
        Property("to", \.to)
        Property("text", \.text)
    }
    var from: ShapeID?
    var to: ShapeID?
    var text: MentionText
    init(from: ShapeID? = nil, to: ShapeID? = nil, text: MentionText = "") {
        self.from = from
        self.to = to
        self.text = text
    }
    init() { self.init(from: nil, to: nil) }
}

struct BondDefinition {}

extension BondDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Bond>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Bond>, in context: ShapeContext) -> ShapeGeometry {
        func center(_ id: ShapeID?) -> CGPoint? {
            guard let bounds = id.flatMap(context.geometry(of:))?.bounds, !bounds.isNull, !bounds.isInfinite else { return nil }
            return CGPoint(x: bounds.midX, y: bounds.midY)
        }
        guard let from = center(shape.props.from), let to = center(shape.props.to) else {
            return ShapeGeometry(outline: [], bounds: .zero, isClosed: false)
        }
        // As an arrow's is: where its pill goes (the lead of its label) is where Adornments' layout input says it is as wide, at the
        // middle of the line, the first face of them, and the label is that and its padding.
        guard let face = context.layoutInput(AdornmentLead.faces, of: shape)?.sizes.first else {
            return ShapeGeometry(outline: [from, to], isClosed: false)
        }
        let middle = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let label = CGRect(x: (middle.x - (face.width + 8) / 2).rounded(), y: (middle.y - (face.height + 8) / 2).rounded(),
                           width: face.width + 8, height: face.height + 8)
        let lead = CGRect(x: label.minX + 4, y: label.minY + 4, width: face.width, height: face.height)
        return ShapeGeometry(outline: [from, to], bounds: CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(from.x - to.x), height: abs(from.y - to.y)).union(label), isClosed: false, label: label, labelLead: lead)
    }
}

extension BondDefinition: ShapeReferencing {
    /// A shape that goes (or is left out of a copy) is let go of: that end is free.
    func remappingReferences(of shape: ShapeRecord<Bond>, _ map: (ShapeID) -> ShapeID?, in _: ShapeContext) -> Bond? {
        Bond(from: shape.props.from.flatMap(map), to: shape.props.to.flatMap(map), text: shape.props.text)
    }
}

/// Bonds, which relate as an arrow does (`typeable()`, `relating()`), and the edge each carries.
struct BondsPlugin: CanvasPlugin {
    var id: PluginID { "bonds" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.edgeType(BondEdge.self)
        registrar.edges(Bond.self) { record, _, sink in
            guard let bond = record.props as? Bond, let from = bond.from, let to = bond.to else { return }
            sink.emit(BondEdge.id, from: from, to: to)
        }
        registrar.shape(BondDefinition()) { bond in
            bond.typeWords(\.text, drawnIn: { _ in nil })
            bond.typeable()
            bond.relating()
        }
    }
}

/// What makes edges for `canvas draw`, with bonds: no channel, no side, the pair and its `is` the identity (TypeNamesPlugin's).
struct BondEdgesPlugin: CanvasPlugin {
    var id: PluginID { "bond-edges" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.drawEdges(kind: { _ in Bond.kind },
                            attributes: [],
                            sides: { _, _ in [:] },
                            ends: { record, _ in
                                guard let bond = record.typed(as: Bond.self)?.props, let from = bond.from, let to = bond.to else { return nil }
                                return (from, to)
                            },
                            make: { request, existing, _ in
                                existing ?? AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: request.from, to: request.to)))
                            })
    }
}

/// Whether a relay may stand for a shape: metadata a test writes on a shape, as a person makes one public.
enum Open: ShapeMetaKey {
    static let owner: PluginID = "relays"
    static let name = "open"
    typealias Value = Bool
}

/// A pill: it stands for the shapes it cites, and says what it stands for.
struct Relay: BoxShapeProps {
    static let kind: ShapeKind = "relay"
    static let properties = Properties<Relay> {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
        Property("says", \.says)
    }
    var frame: CGRect
    var stands: [Citation]
    var says: String
    init(_ frame: CGRect = CGRect(x: 0, y: 0, width: 100, height: 32), stands: [ShapeID] = [], says: String = "") {
        self.frame = frame
        self.stands = stands.map(Citation.init)
        self.says = says
    }
    init() { self.init(CGRect(x: 0, y: 0, width: 100, height: 32)) }
}

struct RelayDefinition {}

extension RelayDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Relay>, in context: RenderContext) {}
}

/// Relays, which stand for the open shapes they cite (a memo or a slip), say how a shape is made open, and
/// call what they stand for what they say.
struct RelaysPlugin: CanvasPlugin {
    var id: PluginID { "relays" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(RelayDefinition()) { relay in
            relay.standsIn(admitting: { target, _ in target.meta[Open.self] == true },
                           needs: "open",
                           fulfilling: { record, _ in
                               record.meta[Open.self] = true
                               return true
                           },
                           calls: { shape, _ in shape.props.says.isEmpty ? nil : shape.props.says },
                           makes: { props, target, label in
                               props.stands = [Citation(target)]
                               props.says = label
                           }) { shape, _ in
                shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape))
            }
            // A tool that places it, from which a pill is made for a shape (`StandIns.makers`).
            relay.tool(label: "Relay", systemImage: "arrow.right", placing: relay.placement(size: CGSize(width: 100, height: 32)) { Relay() })
        }
    }
}

/// An editor with bonds, and relays, and pockets (boards a bond may be drawn on), on `file`.
@MainActor func bondEditor(file: CanvasFile? = nil, more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    try rowEditor(file: file, more: [BondsPlugin(), RelaysPlugin(), PocketsPlugin()] + more)
}

extension CanvasEditor {
    /// A relationship type: a type with the mark, titled.
    @discardableResult
    func addRelationshipType(_ title: String? = nil, at origin: CGPoint = CGPoint(x: 400, y: 40)) -> ShapeID {
        var record = slipTypeRecord(TypeSchemaProperty.starter, title: title, at: origin)
        record[RelationshipProperty.self] = true
        transact { $0.insert(record) }
        return record.id
    }

    /// A bond from one shape to another, named `name`, a relationship of `types`.
    @discardableResult
    func addBond(_ from: ShapeID?, _ to: ShapeID?, name: String = "", of types: [ShapeID] = [], rule: EndRule? = nil) -> ShapeID {
        var record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Bond(from: from, to: to, text: MentionText(plain: name))))
        if !types.isEmpty { record[IsAProperty.self] = types.map(TypeLink.init) }
        if let rule { record[RelationshipEndProperty.self] = rule }
        transact { $0.insert(record) }
        return record.id
    }

    /// A pill that stands for `shapes`, saying `says`.
    @discardableResult
    func addRelay(standingFor shapes: [ShapeID], says: String = "", at origin: CGPoint = CGPoint(x: 40, y: 700)) -> ShapeID {
        let record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Relay(CGRect(origin: origin, size: CGSize(width: 100, height: 32)), stands: shapes, says: says)))
        transact { $0.insert(record) }
        return record.id
    }

    /// Makes a shape open, as a person makes one public.
    func open(_ id: ShapeID) {
        transact { $0.update(id) { $0.meta[Open.self] = true } }
    }
}

/// What the relationship index told, commit after commit.
@MainActor final class RelationshipHeard {
    var changes: [RelationshipChange] = []
    var last: RelationshipChange? { changes.last }
    init(_ editor: CanvasEditor) {
        editor.relationships?.onChange { [weak self] in self?.changes.append($0) }
    }
}

/// A bond editor that `canvas draw` may draw on: names, Types' words, and a filler of Draw's edges that makes bonds.
@MainActor func typeEditorWithDraw() throws -> CanvasEditor {
    let editor = try bondEditor(more: [DrawPlugin(), TitleNamesPlugin(), TypeNamesPlugin(), FieldValuesPlugin(), ValidationChecksPlugin(), BondEdgesPlugin()])
    editor.viewportDidResize(to: CGSize(width: 800, height: 600))
    return editor
}

/// Runs a `canvas draw` script on the editor.
@MainActor func drawScript(_ script: String, on editor: CanvasEditor) throws {
    _ = try draw(script: script, dryRun: false, reveal: false, program: "canvas", in: editor)
}
