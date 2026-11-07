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
