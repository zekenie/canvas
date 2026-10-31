import CanvasRPC
import QueryLanguage

// A query's refusal as every command that takes a query says it (`canvas query`, `canvas decide`), and the one error
// for an app with no query engine.

extension AutomationError {
    /// The most of a query's line a refusal quotes, around what's wrong, in characters.
    public static let queryQuoted = 200

    /// A query's refusal as the command line reports it: its reason, message and hint, and where in `text` (the query as
    /// sent) it is, the line as written there (at most `queryQuoted` characters of it, around what's wrong, the column in
    /// what's quoted), so the caret `canvas` draws under it by `column` lands on what's wrong; and every problem found,
    /// each where it is. Nil `text`: a refusal of no part of a query (a deadline, a closed file).
    public init(_ error: QueryError, in text: String?, details: [String: JSON] = [:]) {
        let place = text.flatMap { error.located(in: $0, quoting: Self.queryQuoted) }
        self.init(error.message, reason: error.reason.rawValue, hint: error.hint, line: place?.line, column: place?.column, length: place?.length,
                  statement: place?.statement, errors: error.errors.map { AutomationError($0, in: text) }, details: details)
    }

    /// No query engine in this app (no `QueriesPlugin`).
    public static var noQueries: AutomationError { AutomationError("This app can't answer queries.", reason: "no_queries") }
}
