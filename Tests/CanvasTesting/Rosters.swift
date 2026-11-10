import AppKit
@_spi(Host) import Canvas
import Geometry

/// A roster: a box with a row a name (`PartedShape`), each row an id of the roster's own, 20 world units tall under a
/// 10-unit head, its rows' rects in its geometry and a row folded away (`folded`) shown at the last row shown. The
/// fixture the core's part basics are held over.
public struct Roster: BoxShapeProps {
    public static let kind: ShapeKind = "roster"
    public static let properties = Properties<Roster> {
        Property("frame", \.frame).required()
        Property("rows", \.rows)
        Property("folded", \.folded)
    }
    public var frame: CGRect
    public var rows: [RosterRow]
    /// How many rows, from the end, are folded away.
    public var folded: Int

    public init(_ frame: CGRect, rows: [RosterRow] = [], folded: Int = 0) {
        self.frame = frame
        self.rows = rows
        self.folded = folded
    }
}

extension Roster {
    public init() { self.init(.zero) }
    /// Where a roster's rows start under its top edge, and how tall each is.
    public static let head: CGFloat = 10
    public static let rowHeight: CGFloat = 20
}

/// A roster's row: its id, the roster's own, and its name. Named in its list as `canvastesting.roster-row`.
public struct RosterRow: SchemaDefined, Hashable, Sendable {
    public static let properties = Properties<RosterRow>(definition: "roster-row") {
        Property("id", \.id).required()
        Property("name", \.name)
    }
    public var id: PartID
    public var name: String

    public init(id: PartID = PartID(), name: String) {
        self.id = id
        self.name = name
    }

    public init() { self.init(name: "") }
}

struct RosterDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Roster>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemGray)
    }

    /// Its box, and a row a rect as wide as it, `head` down and `rowHeight` apart; the rows folded away are where the last
    /// row shown is, not shown.
    func geometry(of shape: ShapeRecord<Roster>, in context: ShapeContext) -> ShapeGeometry {
        let frame = shape.frame, rows = shape.props.rows, shown = max(0, rows.count - shape.props.folded)
        let parts = rows.enumerated().map { index, row in
            let line = min(index, max(0, shown - 1))
            return PartFrame(id: row.id, rect: CGRect(x: frame.minX, y: frame.minY + Roster.head + CGFloat(line) * Roster.rowHeight,
                                                      width: frame.width, height: Roster.rowHeight), isShown: index < shown)
        }
        return ShapeGeometry(outline: frame.polygon, bounds: frame, parts: PartFrames(parts))
    }
}

extension RosterDefinition: PartedShape {
    /// Each row as a Member, a crown before the first.
    func parts(of shape: ShapeRecord<Roster>) -> [PartName] {
        shape.props.rows.enumerated().map { index, row in
            PartName(id: row.id, name: row.name, kindWord: "Member", lead: index == 0 ? .symbol("crown") : .none)
        }
    }
}

/// Rosters, in a plugin of their own so no other test's registry report changes. Install beside `FixturesPlugin`.
public struct RostersPlugin: CanvasPlugin {
    public let id: PluginID
    public init(id: PluginID = "rosters") { self.id = id }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(RosterDefinition()) { _ in }
    }
}

/// A muster: a roster whose kind takes what's bound to it along (`TakesBoundShapes`), so a strap at one of its rows goes
/// with the row. Its rows are `RosterRow`s, laid out as a roster's.
public struct Muster: BoxShapeProps {
    public static let kind: ShapeKind = "muster"
    public static let properties = Properties<Muster> {
        Property("frame", \.frame).required()
        Property("rows", \.rows)
    }
    public var frame: CGRect
    public var rows: [RosterRow]

    public init(_ frame: CGRect, rows: [RosterRow] = []) {
        self.frame = frame
        self.rows = rows
    }

    public init() { self.init(.zero) }
}

struct MusterDefinition: ShapeDefinition, TakesBoundShapes {
    func render(_ shape: ShapeRecord<Muster>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemGray)
    }

    func geometry(of shape: ShapeRecord<Muster>, in context: ShapeContext) -> ShapeGeometry {
        let frame = shape.frame
        let parts = shape.props.rows.enumerated().map { index, row in
            PartFrame(id: row.id, rect: CGRect(x: frame.minX, y: frame.minY + Roster.head + CGFloat(index) * Roster.rowHeight, width: frame.width, height: Roster.rowHeight))
        }
        return ShapeGeometry(outline: frame.polygon, bounds: frame, parts: PartFrames(parts))
    }
}

extension MusterDefinition: PartedShape {
    func parts(of shape: ShapeRecord<Muster>) -> [PartName] {
        shape.props.rows.map { PartName(id: $0.id, name: $0.name, kindWord: "Entry") }
    }
}

/// A strap: a box bound at each end to a shape, or a part of one (a row of a roster or a muster), as an arrow will be.
/// The fixture `removeParts` and `moveParts` are held over.
public struct Strap: BoxShapeProps {
    public static let kind: ShapeKind = "strap"
    public static let properties = Properties<Strap> {
        Property("frame", \.frame).required()
        Property("from", \.from)
        Property("to", \.to)
    }
    public var frame: CGRect
    public var from: PartAddress?
    public var to: PartAddress?

    public init(_ frame: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10), from: PartAddress?, to: PartAddress?) {
        self.frame = frame
        self.from = from
        self.to = to
    }

    public init() { self.init(from: nil, to: nil) }
}

struct StrapDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Strap>, in context: RenderContext) {}
}

extension StrapDefinition: ShapeReferencing {
    /// An end whose shape goes is let go of: nil.
    func remappingReferences(of shape: ShapeRecord<Strap>, _ map: (ShapeID) -> ShapeID?, in _: ShapeContext) -> Strap? {
        func moved(_ end: PartAddress?) -> PartAddress? {
            end.flatMap { end in map(end.shape).map { PartAddress($0, part: end.part) } }
        }
        var strap = shape.props
        strap.from = moved(strap.from)
        strap.to = moved(strap.to)
        return strap
    }

    func boundParts(of shape: ShapeRecord<Strap>) -> [PartAddress] {
        [shape.props.from, shape.props.to].compactMap { $0?.part == nil ? nil : $0 }
    }

    func movingParts(of shape: ShapeRecord<Strap>, _ move: (PartAddress) -> PartAddress) -> Strap? {
        var strap = shape.props
        strap.from = strap.from.map { $0.part == nil ? $0 : move($0) }
        strap.to = strap.to.map { $0.part == nil ? $0 : move($0) }
        return strap == shape.props ? nil : strap
    }
}

extension Strap: Equatable {}

/// Musters and straps, in a plugin of their own so no other test's registry report changes. Install beside
/// `FixturesPlugin` and `RostersPlugin`; `log` hears every `partsMoved`.
public struct StrapsPlugin: CanvasPlugin {
    public let id: PluginID
    let log: PartsMovedLog?
    public init(id: PluginID = "straps", log: PartsMovedLog? = nil) {
        self.id = id
        self.log = log
    }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(MusterDefinition()) { _ in }
        registrar.shape(StrapDefinition()) { _ in }
        if let log { registrar.partsMoved { moves, _ in log.moves.append(moves) } }
    }
}

/// What `partsMoved` heard, in order.
@MainActor
public final class PartsMovedLog {
    public var moves: [[PartAddress: PartAddress]] = []
    public init() {}
}
