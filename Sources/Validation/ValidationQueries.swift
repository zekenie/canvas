import Canvas
import Queries

/// `:invalid` and `:warned`, in Validation: a shape with an error and one with a warning, on
/// every board of the file, not only the one shown. Only the main actor can say (Validation's
/// rules), so each is asked there, in the query's slices, about the shape as the app has it then:
/// from Validation's cache while that's current (the board shown, no commit since the query
/// started, and the shape not waiting to be checked again: `cachedResult(for:)`, which never checks
/// anything), else by running its kind's rules against the board it's on as the app has it
/// (`registry.validationIssues(of:in:)`), as Validation would once that board is shown. Both read the
/// editor (`QueryReads.editor`): the rules run over the app's live board, and Validation's cache is
/// the editor's. A row of a query that names `:invalid` lists its errors (`problems`: each a field and
/// where in it when Validation says, and its words), read the same way.
public struct ValidationQueriesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "validation-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        Self.word(.invalid, "it has an error", severity: .error, into: &registrar)
        Self.word(.warned, "it has a warning", severity: .warning, into: &registrar)
    }

    /// The words it adds.
    enum Word: String {
        case invalid, warned
    }

    /// `:word`, a shape with an issue of `severity`.
    private static func word(_ word: Word, _ summary: String, severity: Severity, into registrar: inout PluginRegistrar) {
        let problems: (@MainActor (AnyShapeRecord, BoardID, Void, QueryMainContext) -> [ShapeProblem])? = severity == .error ? errors : nil
        registrar.queryPseudoClass(word.rawValue, summary, example: ":\(word.rawValue)",
                                   prepare: { _ in () },
                                   matches: { _, _ in .onMain },
                                   onMain: { record, board, _, context in has(severity, record, on: board, context) },
                                   problems: problems)
    }

    /// What `:invalid` says of a shape: each error, a field's with where in its value.
    @MainActor
    private static func errors(_ record: AnyShapeRecord, on board: BoardID, _: Void, _ context: QueryMainContext) -> [ShapeProblem] {
        issues(of: record, on: board, context).filter { $0.severity == .error }.map { issue in
            ShapeProblem(field: issue.field, path: issue.path, class: "wrong", message: issue.message)
        }
    }

    /// Whether a shape, on `board` as the app has it now, has an issue of `severity`.
    @MainActor
    private static func has(_ severity: Severity, _ record: AnyShapeRecord, on board: BoardID, _ context: QueryMainContext) -> Bool {
        issues(of: record, on: board, context).contains { $0.severity == severity }
    }

    /// A shape's issues, on `board` as the app has it now.
    @MainActor
    private static func issues(of record: AnyShapeRecord, on board: BoardID, _ context: QueryMainContext) -> [ValidationIssue] {
        let editor = context.editor
        // Validation's cache, only while it holds what the query would find: the board shown, and
        // nothing committed since the query started.
        if board == editor.board, editor.revision == context.revision,
           case .current(let result)? = editor.validation?.cachedResult(for: record.id) {
            return result?.issues ?? []
        }
        return context.registry.validationIssues(of: record, in: context.shapes(on: board), editor: editor)
    }
}
