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
                // What a shape still needs is no line here: `worstFirst` leaves it out, and so does the tone. What can
                // be done about an issue is under its line.
                let issues = context.service(ValidationEngine.self)?.result(for: shape.id)?.worstFirst ?? []
                let walk = context.service(IssueWalk.self)
                return issues.enumerated().compactMap { index, issue in
                    DetailStatus.Tone(issue.severity).map { tone -> DetailStatus in
                        // An action run from the line is told to the issue walk first, which an Ignore's row reads "ignored" by.
                        var actions = issue.actions.map { action in
                            DetailStatusAction(action.title) {
                                walk?.willPerform(action.role, onIssueAt: index, among: issues, of: shape.id)
                                action.perform()
                            }
                        }
                        // After its own: "9 of 63", where the issue's walk would begin (or the walk running goes to).
                        if let more = walk?.lineAction(for: issue, of: shape.id) { actions.append(more) }
                        return DetailStatus(issue.message, tone: tone, actions: actions)
                    }
                }
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
