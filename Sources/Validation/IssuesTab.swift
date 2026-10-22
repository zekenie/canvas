import Canvas
import DetailPanel

/// Validation's Issues tab: each shape's validation issues, worst first, in an Issues tab of the
/// detail panel, which shows only while the shape has some. A plugin of its own, so a list can
/// install Validation without the detail panel (the registry refuses a contribution to a point
/// whose owner isn't installed).
public struct ValidationDetailsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "validation-details" }

    public func register(into registrar: inout PluginRegistrar) {
        // Every shape is checked (its schema, at least), so any may have issues.
        registrar.forEveryShape { every in
            every.detailStatus(in: IssuesTab.self) { shape, context in
                // What a shape still needs is no line here: `worstFirst` leaves it out, and so does the tone.
                (context.service(ValidationEngine.self)?.result(for: shape.id)?.worstFirst ?? [])
                    .compactMap { issue in DetailStatus.Tone(issue.severity).map { DetailStatus(issue.message, tone: $0) } }
            }
        }
    }
}

/// A shape's validation issues. It comes and goes with them, so it trails every other tab, Style
/// too, which keep their places as it does.
public enum IssuesTab {}

extension IssuesTab: DetailTab {
    public static var title: String { "Issues" }
    public static var order: Order<Self> { .after(StyleTab.self) }
}

extension DetailStatus.Tone {
    /// Nil for what a shape still needs, which is no status.
    init?(_ severity: Severity) {
        switch severity {
        case .warning: self = .warning
        case .error: self = .error
        case .incomplete: return nil
        }
    }
}
