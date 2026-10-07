import AppKit
import Canvas
import CoreGraphics

/// A line from one point to another, drawn black, `Cable.width` world units wide with round caps:
/// an open shape with no box, as an arrow is, whose kind says how wide its line is (`StrokedShape`),
/// so tests can hold the core's cover of such a line to a width they know.
public struct Cable: ShapeProps {
    public static let kind: ShapeKind = "cable"
    public static let properties = Properties<Cable> {
        Property("from", \.from)
        Property("to", \.to)
    }
    /// How wide it's drawn, in world units: 6, so its width on screen is whole at 50%, 100% and 200%.
    public static let width: CGFloat = 6
    public var from: CGPoint
    public var to: CGPoint
    public init(from: CGPoint, to: CGPoint) {
        self.from = from
        self.to = to
    }
}

extension Cable {
    public init() { self.init(from: .zero, to: .zero) }
}

public struct CableDefinition {
    public init() {}
}

extension CableDefinition: ShapeDefinition {
    public func render(_ shape: ShapeRecord<Cable>, in context: RenderContext) {
        let cg = context.cg
        cg.move(to: shape.props.from)
        cg.addLine(to: shape.props.to)
        cg.setStrokeColor(CGColor(gray: 0, alpha: 1))
        cg.setLineWidth(Cable.width)
        cg.setLineCap(.round)
        cg.strokePath()
    }

    public func geometry(of shape: ShapeRecord<Cable>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: [shape.props.from, shape.props.to], isClosed: false)
    }
}

extension CableDefinition: StrokedShape {
    public func lineWidth(of shape: ShapeRecord<Cable>, in context: ShapeContext) -> CGFloat { Cable.width }
}

/// Cables ("cable"), no tool. Install beside `FixturesPlugin`.
public struct CablesPlugin: CanvasPlugin {
    public let id: PluginID
    public init(id: PluginID = "cables") { self.id = id }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(CableDefinition())
    }
}
