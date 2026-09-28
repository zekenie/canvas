import Automation
import Canvas
import Validation

/// A bridge between two horizontals: what `canvas draw` says is wrong with a shape it drew is what
/// Validation finds (`registry.validationIssues(of:in:)`: every rule for its kind, the schema's
/// bounds included), against the board as the script leaves it. An error is still drawn, and the
/// board outlines it red. Automation has never heard of validity, nor Validation of the command
/// line; this module's imports are the only edge between them.
public struct ValidationChecksPlugin: CanvasPlugin {
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
