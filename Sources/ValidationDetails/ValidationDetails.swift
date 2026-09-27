import Canvas
import DetailPanel
import Validation

/// A bridge between two horizontals: each shape's validation issues, worst first, in an Issues tab
/// of the detail panel, which shows only while the shape has some. Validation has never heard of
/// the panel, nor the panel of validity; this module's imports are the only edge between them in
/// Package.swift.
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

/// A shape's validation issues. It comes and goes with them, so it trails every other tab and
/// never moves one.
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
