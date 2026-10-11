import Automation
import Canvas
import Validation

/// Draw's warnings, in DrawLexicon: what `canvas draw` says is wrong with a shape it drew is what
/// Validation finds (`registry.validationIssues(of:in:)`: every rule for its kind, the schema's
/// bounds included), against the board as the script leaves it. An error is still drawn, and the
/// board outlines it red.
public struct ValidationChecksPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "validation-checks" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawChecks { record, shapes in
            shapes.registry.validationIssues(of: record, in: shapes).map { issue in
                DrawIssue(issue.message, isError: issue.severity == .error, field: issue.field)
            }
        }
    }
}
