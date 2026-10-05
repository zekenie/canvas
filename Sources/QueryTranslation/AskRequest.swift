import Canvas
import Foundation
import LanguageModels
import Queries
import QueryLanguage

/// How `--ask` asks: which model, with what (every setting of the model in this one place), and the
/// command's bounds: how many titles and selected shapes the request names, how long the whole
/// command may take, and until when a refused query is sent back for a second try.
public struct AskStyle: Sendable, Equatable {
    /// The model, by its id; nil for the editor's own (`editor.languageModel`'s, Claude Haiku 4.5).
    public var model: String?
    /// Nil sends none: the model's default.
    public var temperature: Double?
    public var maxTokens: Int
    /// How much the model spends on its answer, thinking included; nil for none said (Haiku 4.5
    /// refuses a request that says one).
    public var effort: String?
    /// Whether the service may answer with another model when this one declines; nil for never.
    public var fallbacks: ModelFallbacks?

    public init(model: String? = nil, temperature: Double? = nil, maxTokens: Int, effort: String? = nil, fallbacks: ModelFallbacks? = nil) {
        self.model = model
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.effort = effort
        self.fallbacks = fallbacks
    }

    /// The editor's model, Claude Haiku 4.5: its most predictable answers, and room for a query.
    public static let haiku = AskStyle(temperature: 0, maxTokens: 400)
    /// Claude Sonnet 5.5: no temperature (it refuses any but its default), room to think (it
    /// thinks adaptively when not told otherwise), a little effort, and the service's fallback on
    /// a decline (a cyber or frontier-LLM one is answered by Sonnet 5; any other still comes back
    /// a refusal, `declined`).
    public static let sonnet = AskStyle(model: "claude-sonnet-5-5", maxTokens: 2_048, effort: "low", fallbacks: .default)
    /// What ships: the model the evaluations picked, the cheaper that clears the bar. Round 2
    /// (`scripts/query-prompts/results.tsv`, 192 runs each) put Sonnet 5.5 at 192 of 192 first try;
    /// Haiku 4.5 at 189, under the bar in one category (80% of "state": it read "links to" as
    /// mentions too), so Sonnet 5.5 is the only one that clears it. Every request names it; the
    /// editor's own model stays Haiku 4.5, for the schema cards.
    public static let shipped = sonnet

    /// The style for a model named by its id (an evaluation's `QUERY_MODEL`): Sonnet 5.5's for its
    /// id, else the editor's model's settings with that model (none: the editor's own).
    public static func named(_ model: String?) -> AskStyle {
        if model == sonnet.model { return sonnet }
        var style = haiku
        style.model = model.flatMap { $0.isEmpty ? nil : $0 }
        return style
    }

    /// Titles named in the request, at most.
    public static let titles = 200
    /// Selected shapes named in the request, at most.
    public static let selected = 20
    /// The whole command: the request's assembly, the model's answers and every query run, under
    /// the 60 s `canvas` waits for it (`x-timeout`).
    public static let deadline: Duration = .seconds(55)
    /// A refused query is sent back for a second try only before this.
    public static let repairBefore: Duration = .seconds(40)
}

/// The request `--ask` sends: its system prompt, and one user message of tagged blocks, each
/// `<tag>`, its text, `</tag>`, a blank line between them, one with nothing to say left out: the
/// question, the vocabulary (`QueryVocabulary.text`), where the person is, and the titles. On a
/// second try, the first answer follows as the model's, and a message of one block, the error.
///
/// Nothing else leaves the machine: no shape's text, only its title, kind, and where it is, and a
/// selected shape's id when it has no title.
public enum AskRequest {
    /// The first request.
    ///
    /// `selection` says whether the selected shapes are named in `<board>`: not for a query that is
    /// stored and run later (`TranslationContext.reference`), where whatever is selected is the pill
    /// being typed into.
    public static func request(question: String, vocabulary: String, where place: QueryWhere, titles: [QueryTitle], system: String,
                               style: AskStyle, selection: Bool = true) -> ModelRequest {
        let message = [
            block(.question, question),
            block(.vocabulary, vocabulary),
            block(.board, board(place, selection: selection)),
            block(.titles, listed(titles)),
        ].compactMap { $0 }.joined(separator: "\n\n")
        return ModelRequest(system: system, messages: [.user(message)], maxTokens: style.maxTokens, temperature: style.temperature,
                            model: style.model, effort: style.effort, fallbacks: style.fallbacks)
    }

    /// The second try: the request, the model's first answer as it wrote it, and `error`.
    public static func repairing(_ request: ModelRequest, answer: String, error: String) -> ModelRequest {
        var request = request
        request.messages += [.assistant(answer.trimmingCharacters(in: .whitespacesAndNewlines)), .user(block(.error, error) ?? "")]
        return request
    }

    /// The error block's text for a refused query: the query, then its refusal (reason, message and
    /// hint).
    public static func refusal(of query: String, _ error: QueryError) -> String {
        "query: \(query)\nrefused: \(error.reason.rawValue): \(said(error))"
    }

    /// A refusal's message, and its hint after it.
    static func said(_ error: QueryError) -> String {
        error.hint.map { "\(error.message) \($0)" } ?? error.message
    }

    /// What a second try is told when the first answer was several lines, the last no query.
    public static let oneLine = "Reply with the query alone, on one line."

    /// The blocks, by their tags, in the order they're sent.
    enum Tag: String {
        case question, vocabulary, board, titles, error
    }

    /// `<tag>`, the text trimmed, `</tag>`; nil for no text.
    static func block(_ tag: Tag, _ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : "<\(tag.rawValue)>\n\(text)\n</\(tag.rawValue)>"
    }

    /// Where the person is: the board shown, by the path of names to it ("the top board" at the top),
    /// and what's selected: a titled shape by its title and kind, an untitled one by its kind and id.
    static func board(_ place: QueryWhere, selection: Bool = true) -> String {
        let board = place.path.isEmpty ? "the top board" : "the board inside \(place.path.joined(separator: " › "))"
        guard selection else { return "The person is looking at \(board)." }
        guard !place.selected.isEmpty else { return "The person is looking at \(board). Nothing is selected." }
        var named = place.selected.map { shape in
            shape.title.map { "\(quoted($0)) (\(shape.kind.rawValue))" } ?? "an untitled \(shape.kind.rawValue), #\(shape.id)"
        }
        if place.selectedCount > place.selected.count { named.append("and \(place.selectedCount - place.selected.count) more") }
        return "The person is looking at \(board). Selected: \(named.joined(separator: ", "))."
    }

    /// A title a line, as a query writes it, its kind, and the boards it's inside from the top.
    static func listed(_ titles: [QueryTitle]) -> String {
        titles.map { title in
            "\(quoted(title.title)) \(title.kind.rawValue)" + (title.inside.isEmpty ? "" : ", in " + title.inside.joined(separator: " › "))
        }.joined(separator: "\n")
    }

    /// In double quotes, as the language writes a title.
    static func quoted(_ title: String) -> String {
        Head.title(title, QuerySpan(offset: 0, length: 0)).canonical
    }
}
