import Canvas
import Draw

/// Draw's warnings, in Validation: what `canvas draw` says is wrong with a shape it drew is what
/// Validation finds (`registry.validationIssues(of:in:)`: every rule for its kind, the schema's
/// bounds included), against the board as the script leaves it. An error is still drawn, and the
/// board outlines it red. And which other shapes a run's writes reach is what the rules say they touch
/// (`registry.validationTouched(by:in:)`), so a run warns of each issue it brings to a shape it did not write.
public struct ValidationChecksPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "validation-checks" }

    public func register(into registrar: inout PluginRegistrar) {
        // What lists every shape a run broke, said after the twentieth: Validation's own query words, an error, a warning
        // or what a shape still needs.
        let words = [ValidationQueriesPlugin.Word.invalid, .warned, .incomplete].map { ":\($0.rawValue)" }.joined(separator: ", ")
        let rest = "canvas query \"\(words)\""
        registrar.drawChecks(touched: { changes, shapes in
            shapes.registry.validationTouched(by: changes, in: shapes)
        }, rest: rest) { record, shapes in
            shapes.registry.validationIssues(of: record, in: shapes).map { issue in
                DrawIssue(issue.message, level: issue.severity.drawLevel, field: issue.field)
            }
        }
    }
}

extension Severity {
    /// How Draw says it: its own words for the same three levels.
    fileprivate var drawLevel: DrawIssue.Level {
        switch self {
        case .error: .error
        case .warning: .warning
        case .incomplete: .incomplete
        }
    }
}
