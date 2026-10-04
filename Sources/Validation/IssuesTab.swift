import Canvas
import DetailPanel

/// Validation's Issues tab: each shape's validation issues, worst first, in an Issues tab of the
/// detail panel, which shows only while the shape has some. A plugin of its own, so a list can
/// install Validation without the detail panel (the registry refuses a contribution to a point
/// whose owner isn't installed).
public struct ValidationDetailsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "validation-details" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.detailStatusForEveryShape(in: IssuesTab.self) { shape, context in
            (context.service(ValidationEngine.self)?.result(for: shape.id)?.worstFirst ?? [])
                .map { DetailStatus($0.message, tone: DetailStatus.Tone($0.severity)) }
        }
    }
}

/// A shape's validation issues. It comes and goes with them, so it trails every other tab, which
/// keep their order as it does.
public enum IssuesTab {}

extension IssuesTab: DetailTab {
    public static var title: String { "Issues" }
    public static var order: Int { 300 }
}

extension DetailStatus.Tone {
    init(_ severity: Severity) {
        self = switch severity {
        case .warning: .warning
        case .error: .error
        }
    }
}
