import Automation
import Canvas
import CanvasRPC
import Foundation
import Queries
import QueryLanguage

/// What `canvas query` takes: a query, or a question for the app's model to write one for; how many
/// rows to list; and which of each row's attributes to show, if any.
struct QueryParams: SchemaDefined {
    static let properties = Properties<QueryParams>(title: "query") {
        Property("query", \.query).keywords(["x-stdin": true, "x-value-name": "query"])
            .description("What to find, in the query language (the canvas skill's reference/query.md).")
        Property("ask", \.ask).maxLength(QueryParams.questionLength)
            .keywords(["x-stdin": true, "x-value-name": "question", "x-timeout": .number(QueryParams.askWait)])
            .description("A question in English instead: the app has Claude write the query (with the key in Settings), runs it, and says what it wrote.")
        Property("limit", \.limit).minimum(1).maximum(Double(QueryBudget.maxRows))
            .description("The most rows; count counts them all.")
        Property("count", \.count).description("Only how many match.")
        Property("brief", \.brief).description("Rows without their properties.")
        Property("fields", \.fields).keywords(["x-value-name": "attribute"])
            .description("Only these attributes in each row, whole.")
    }

    /// The longest question `--ask` takes, in characters.
    static let questionLength = 2_000
    /// How long `canvas` waits for an `--ask`, in seconds: the command's own deadline
    /// (`AskStyle.deadline`), and time for the request's wait, the answer's JSON and the wire.
    static let askWait: Double = 60

    var query: String?
    var ask: String?
    var limit = QueryBudget.rows
    var count = false
    var brief = false
    var fields: [String] = []

    /// What's asked: a query, or a question.
    enum Asked: Equatable {
        case query(String)
        case question(String)
    }

    /// The query or the question, exactly one of them given (and a question that isn't blank);
    /// refused as the params' fault otherwise, and for `--brief` with `--fields`.
    func asked() throws(AutomationError) -> Asked {
        let asked: Asked
        switch (query, ask.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
        case (let text?, nil): asked = .query(text)
        case (nil, let question?) where !question.isEmpty: asked = .question(question)
        default: throw Self.invalid(#"Say what to find: a query, or --ask "…"."#)
        }
        if brief && !fields.isEmpty {
            throw Self.invalid("Give --brief or --fields, not both.", hint: "--brief leaves every attribute out; --fields lists only those it names.")
        }
        return asked
    }

    /// Which attributes each row lists: none (`--brief`), those `--fields` names, whole, or all.
    var listing: QueryRequest.Properties {
        brief ? .none : fields.isEmpty ? .all : .only(fields)
    }

    /// Refuses a field no kind of the vocabulary's has as an attribute (`unknown_attribute`), the
    /// params' fault, with the attribute like it: a shape of a kind without one lists none, but one no
    /// kind has is a mistake, which would list nothing anywhere.
    func checkFields(against vocabulary: QueryVocabulary) throws(AutomationError) {
        guard let unknown = fields.first(where: { !vocabulary.isAttribute($0) }) else { return }
        throw AutomationError("No kind has an attribute \(unknown) for --fields to list.", reason: QueryError.Reason.unknownAttribute.rawValue,
                              hint: vocabulary.attribute(like: unknown).map { "Did you mean \($0)?" }
                                  ?? "`\(RPC.commandName) query-vocabulary` lists each kind's attributes.",
                              invalidParams: true)
    }

    private static func invalid(_ message: String, hint: String = "`\(RPC.commandName) help query` says what it takes.") -> AutomationError {
        AutomationError(message, reason: "invalid_params", hint: hint, invalidParams: true)
    }
}

/// What `canvas query-vocabulary` takes: nothing.
struct VocabularyParams: SchemaDefined {
    static let properties = Properties<VocabularyParams>(title: "query-vocabulary") {}
}
