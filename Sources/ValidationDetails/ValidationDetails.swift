import Canvas
import DetailPanel
import Validation

/// A bridge between two horizontals: each shape's validation issues, worst first, at the foot of
/// the detail panel. Validation has never heard of the panel, nor the panel of validity; this
/// module's imports are the only edge between them in Package.swift.
public struct ValidationDetailsPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "validation-details" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.detailStatusForEveryShape { shape, context in
            (context.service(ValidationEngine.self)?.result(for: shape.id)?.issues ?? [])
                .sorted { $0.severity > $1.severity }
                .map { DetailStatus($0.message, tone: DetailStatus.Tone($0.severity)) }
        }
    }
}

extension DetailStatus.Tone {
    init(_ severity: Severity) {
        self = switch severity {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }
}
