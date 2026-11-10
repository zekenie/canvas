import AppKit
@_spi(Host) import Canvas
import CanvasRPC

// A shape that shows another shape of the file in its place (`ShowingShapes`), as a mirror does: what tests of shapes
// drawn and edited in another's place use, so they never depend on References.

/// A box that shows the shape it names (on any board), scaled by `scale`, that shape's world point `origin` drawn at the
/// lens's top-left corner, clipped to the lens. Drawn through another lens, it's a plain lens, showing nothing.
public struct Lens: BoxShapeProps {
    public static let kind: ShapeKind = "lens"
    public static let properties = Properties<Lens> {
        Property("frame", \.frame).required()
        Property("shows", \.shows)
        Property("origin", \.origin)
        Property("scale", \.scale)
    }
    public var frame: CGRect
    public var shows: LensLink?
    public var origin: CGPoint
    public var scale: CGFloat
    public init(_ frame: CGRect, shows: ShapeID? = nil, origin: CGPoint = .zero, scale: CGFloat = 1) {
        self.frame = frame
        self.shows = shows.map(LensLink.init)
        self.origin = origin
        self.scale = scale
    }
}

extension Lens {
    public init() { self.init(.zero) }

    /// From the shown shape's world units into the lens's board's.
    public var transform: CGAffineTransform {
        CGAffineTransform(translationX: frame.minX, y: frame.minY).scaledBy(x: scale, y: scale).translatedBy(x: -origin.x, y: -origin.y)
    }
}

/// The shape a lens shows, by its id, coded as one string; a name (`ShapeNaming`), so a copy of a lens shows the copy of
/// its shape when that came along, and the lens keeps the name once the shape is gone.
public struct LensLink: Codable, Hashable, Sendable, SchemaDescribed, ShapeNaming {
    public var shape: ShapeID

    public init(_ shape: ShapeID) { self.shape = shape }

    public init(from decoder: any Decoder) throws {
        shape = try decoder.singleValueContainer().decode(ShapeID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(shape)
    }

    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("lens-link", of: Self.self) { _ in
            ["type": "string", "format": "uuid", "description": "The shape a lens shows, which may be gone."]
        }
    }

    public func forEachNamedShape(_ body: (ShapeID) -> Void) { body(shape) }

    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> LensLink { LensLink(rename(shape) ?? shape) }
}

/// What a lens's render heard: the zoom it was drawn at, whether it was drawn through another lens, and whether what
/// it shows drew.
@MainActor public final class LensLog {
    public var drawn: [(lens: ShapeID, shownThrough: ShapeID?, showed: Bool)] = []
    public var editedThrough: [ShapeID] = []
    public init() {}
}

struct LensDefinition {
    let log: LensLog
}

extension LensDefinition: ShapeDefinition {
    /// A pale fill, and what it shows over it, clipped to the lens; drawn through another lens, the fill alone.
    func render(_ shape: ShapeRecord<Lens>, in context: RenderContext) {
        context.cg.setFillColor(NSColor(white: 0.85, alpha: 1).cgColor)
        context.cg.fill(shape.frame)
        if context.isEditedThrough { log.editedThrough.append(shape.id) }
        guard let shown = shape.props.shows?.shape, context.shownThrough == nil else {
            log.drawn.append((shape.id, context.shownThrough, false))
            return
        }
        context.cg.saveGState()
        context.cg.clip(to: shape.frame)
        let showed = context.drawShape(inFile: shown, through: shape.props.transform, standingIn: shape.id)
        context.cg.restoreGState()
        log.drawn.append((shape.id, context.shownThrough, showed))
    }
}

extension LensDefinition: CustomSkeleton {
    /// Zoomed out the same: what it shows is drawn as that shape's own skeleton.
    func renderSkeleton(_ shape: ShapeRecord<Lens>, in context: RenderContext) { render(shape, in: context) }
}

extension LensDefinition: ShowingShapes {
    func shownShape(of shape: ShapeRecord<Lens>, in context: ShapeContext) -> ShapeID? { shape.props.shows?.shape }
    func shownTransform(of shape: ShapeRecord<Lens>, in context: ShapeContext) -> CGAffineTransform? {
        shape.props.shows == nil ? nil : shape.props.transform
    }
}

/// The "lens" kind, no tool. Apart from `FixturesPlugin`, so the registry reports tests pin don't change.
public struct LensesPlugin: CanvasPlugin {
    let log: LensLog
    public init(log: LensLog = LensLog()) { self.log = log }
    public var id: PluginID { "lenses" }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(LensDefinition(log: log))
    }
}
