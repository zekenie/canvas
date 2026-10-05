import Canvas
import Queries
import QueryLanguage

@MainActor extension Drawing {
    /// Refuses a query a property holds (`format: x-canvas-query`) that the query engine won't read,
    /// with the engine's own message and hint: syntax and vocabulary only, since a title is read
    /// when the query runs. Nothing is checked without the engine (QueriesPlugin).
    func checkQuery(_ value: JSONValue, _ key: String, _ vocabulary: KindVocabulary) throws(ValueRefusal) {
        guard case .string(let text) = value, vocabulary.isQuery(key), let queries = editor.queries else { return }
        do throws(QueryError) {
            _ = try queries.check(text)
        } catch {
            throw ValueRefusal(message: "\(key): \(error.message)", hint: error.hint)
        }
    }
}
