import AppKit
import Canvas
import Keyboard

public struct Ellipse: BoxShapeProps {
    public static let kind: ShapeKind = "ellipse"
    public var frame: CGRect
    public init(frame: CGRect = .zero) { self.frame = frame }
}

extension PluginID {
    public static let ellipses: PluginID = "ellipses"
}

/// A shape and a tool, with an exact hit test and a smooth outline instead of the defaults.
public struct EllipsesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .ellipses }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(EllipseDefinition()) { ellipse in
            let place = ellipse.placement(size: EllipseStyle.size) { Ellipse() }
            ellipse.tool(label: "Ellipse", systemImage: "circle", shortcut: "o", placing: place)
        }
    }
}

struct EllipseDefinition {}

extension EllipseDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Ellipse>, in context: RenderContext) {
        context.fillWithShadow(CGPath(ellipseIn: shape.frame, transform: nil), EllipseStyle.color)
    }

    /// Enough points that connectors stop visibly on the curve even zoomed all the way in.
    func geometry(of shape: ShapeRecord<Ellipse>, in context: ShapeContext) -> ShapeGeometry {
        let frame = shape.frame, count = 128
        let outline = (0..<count).map { i in
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
            return CGPoint(x: frame.midX + cos(angle) * frame.width / 2, y: frame.midY + sin(angle) * frame.height / 2)
        }
        return ShapeGeometry(outline: outline, bounds: frame)
    }

    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Ellipse>, in context: ShapeContext) -> Bool {
        let frame = shape.frame
        guard frame.width > 0, frame.height > 0 else { return false }
        let x = (point.x - frame.midX) / (frame.width / 2)
        let y = (point.y - frame.midY) / (frame.height / 2)
        return x * x + y * y <= 1
    }

    func indicatorPath(of shape: ShapeRecord<Ellipse>, in context: ShapeContext) -> CGPath {
        CGPath(ellipseIn: shape.frame, transform: nil)
    }
}

@MainActor
enum EllipseStyle {
    static let size = CGSize(width: 200, height: 140)
    static let color = NSColor(srgbRed: 0.62, green: 0.81, blue: 1.0, alpha: 1)
}
