import AppKit
import Canvas

/// The smallest vertical plugin: a kind, how to draw it, and a tool that places it. The rest comes
/// from the core's defaults for shapes with a frame: hit testing, the selection outline, moving,
/// being culled offscreen, and arrows attaching to it.

/// The kind: plain data, named once.
public struct Rectangle: BoxShapeProps {
    public static let kind: ShapeKind = "rectangle"
    public var frame: CGRect
    public init(frame: CGRect = .zero) { self.frame = frame }
}

/// How rectangles look: the only thing a box kind has to say. Conforming in an extension lets the
/// compiler catch a near miss on a requirement that has a default.
struct RectangleDefinition {}

extension RectangleDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Rectangle>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemTeal)
    }
}

public struct RectanglesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "rectangles" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(RectangleDefinition()) { rectangle in
            let place = rectangle.placement(size: CGSize(width: 160, height: 100)) { Rectangle() }
            rectangle.tool(label: "Rectangle", systemImage: "rectangle", shortcut: "r", placing: place)
        }
    }
}
