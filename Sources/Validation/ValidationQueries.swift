import Canvas
import Queries

/// `:invalid`, `:warned` and `:incomplete`, in Validation: a shape with an error, one with a warning and one that still
/// needs something (an issue of the third level, which any rule may say), on every board of the file, not only the one
/// shown. Only the main actor can say (Validation's rules), so each is asked there, in the query's slices, about the shape
/// as the app has it then: from Validation's cache while that's current (the board shown, no commit since the query
/// started, and the shape not waiting to be checked again: `cachedResult(for:)`, which never checks anything), else by
/// running its kind's rules against the board it's on as the app has it (`registry.validationIssues(of:in:)`), as
/// Validation would once that board is shown. All read the editor (`QueryReads.editor`): the rules run over the app's
/// live board, and Validation's cache is the editor's. A row of a query that names `:invalid` lists its errors, one that
/// names `:warned` its warnings and one that names `:incomplete` what it still needs (`problems`: each a field and where
/// in it when Validation says, its class (`wrong`, `warning`, `needed`) and its words), read the same way.
public struct ValidationQueriesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "validation-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        Self.word(.invalid, "it has an error", severity: .error, says: "wrong", into: &registrar)
        Self.word(.warned, "it has a warning", severity: .warning, says: "warning", into: &registrar)
        Self.word(.incomplete, "it still needs something", severity: .incomplete, says: "needed", into: &registrar)
    }

    /// The words it adds.
    enum Word: String {
        case invalid, warned, incomplete
    }

    /// `:word`, a shape with an issue of `severity`; its rows list those issues as `problems` of `class`. A rule may
    /// answer later than its commit (LanguageRules': a decision model's), so a query of it waits while answers are
    /// still arriving, as one that reads edges does.
    private static func word(_ word: Word, _ summary: String, severity: Severity, says problemClass: String, into registrar: inout PluginRegistrar) {
        registrar.queryPseudoClass(word.rawValue, summary, example: ":\(word.rawValue)",
                                   prepare: { _ in () },
                                   matches: { _, _ in .onMain },
                                   onMain: { record, board, _, context in has(severity, record, on: board, context) },
                                   problems: { record, board, _, context in listed(severity, as: problemClass, record, on: board, context) },
                                   settles: true)
    }

    /// What a row says of a shape for a word: each issue of `severity`, a field's with where in its value.
    @MainActor
    private static func listed(_ severity: Severity, as problemClass: String, _ record: AnyShapeRecord, on board: BoardID, _ context: QueryMainContext) -> [ShapeProblem] {
        issues(of: record, on: board, context).filter { $0.severity == severity }.map { issue in
            ShapeProblem(field: issue.field, path: issue.path, class: problemClass, message: issue.message)
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
