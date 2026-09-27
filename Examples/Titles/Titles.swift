import AppKit
import Canvas
import Geometry
import Selection

/// The smallest horizontal plugin: a concern other plugins opt into, one kind at a time. A kind
/// can say what its shapes are called; this plugin shows the title of the shape under the pointer
/// (the select tool's hover, from the Selection horizontal it builds on). The core never learns
/// what a title is.
extension PluginID {
    public static let titles: PluginID = "titles"
}

/// The extension point: this plugin declares it and reads it; others contribute to it.
public enum ShapeTitles: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (AnyShapeRecord) -> String?
    public static var owner: PluginID { .titles }
    /// At most one title per kind: two plugins titling the same kind is an error at startup.
    public static func uniqueKeys(of _: Contribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
}

// Sugar, so opting in is one line and never names the extension point.
extension ShapeRegistrar {
    /// This kind's title: `note.title { $0.props.text }`.
    public mutating func title(_ make: @escaping @MainActor (ShapeRecord<Definition.Props>) -> String?) {
        contribute({ $0.typed(as: Definition.Props.self).flatMap(make) }, to: ShapeTitles.self)
    }
}

extension PluginRegistrar {
    /// A title for a kind another plugin registers.
    public mutating func title<P: ShapeProps>(_: P.Type, _ make: @escaping @MainActor (ShapeRecord<P>) -> String?) {
        contribute({ $0.typed(as: P.self).flatMap(make) }, to: ShapeTitles.self, for: .kind(P.kind))
    }
}

extension Registry {
    /// What a shape is called, if its kind says.
    public func title(of shape: AnyShapeRecord) -> String? {
        contributions(to: ShapeTitles.self, for: shape.kind).first?(shape) ?? nil
    }
}

/// The hovered shape's title, just below it, in view points.
struct TitleOverlay: CanvasOverlay {
    var space: OverlaySpace { .view }

    func draw(in context: OverlayContext) {
        let editor = context.editor
        guard let id = editor.hovered, let shape = editor.document[id], let title = editor.registry.title(of: shape),
              let bounds = context.shapes.geometry(of: id)?.bounds else { return }
        let corner = editor.camera.toView(CGPoint(x: bounds.minX, y: bounds.maxY))
        NSAttributedString(string: title, attributes: TitleStyle.attributes)
            .draw(at: CGPoint(x: corner.x, y: corner.y + TitleStyle.gap))
    }
}

@MainActor
enum TitleStyle {
    static let gap: CGFloat = 6
    static let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12, weight: .medium),
        .foregroundColor: NSColor.secondaryLabelColor,
    ]
}

public struct TitlesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .titles }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.overlay(TitleOverlay())
    }
}
