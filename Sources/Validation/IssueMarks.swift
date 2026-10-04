import Canvas
import SwiftUI
import TableOfContents

/// Validation's marks in the table of contents: a dot on the row of each shape with issues, in the
/// color the canvas outlines it in (red with an error, orange with only warnings), whose tooltip
/// lists them, worst first. So the table of contents shows where the issues are across the board,
/// and a click on a row goes to its shape. A plugin of its own, so a list can have Validation
/// without the table of contents (the registry refuses a contribution to a point whose owner isn't
/// installed).
public struct ValidationContentsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "validation-contents" }

    public func register(into registrar: inout PluginRegistrar) {
        // A rule may look at other shapes, or read a service, so a commit may change the issues of
        // shapes it didn't change: the engine knows which.
        registrar.contentsMarkForEveryShape(affected: { changes, context in
            context.service(ValidationEngine.self)?.affected(by: changes) ?? []
        }) { shape, context in
            guard let result = context.service(ValidationEngine.self)?.result(for: shape.id), let worst = result.worst else { return nil }
            return ContentsMark(color: Color(nsColor: worst.color), help: result.worstFirst.map(\.message).joined(separator: "\n"))
        }
    }
}
