import Automation
import Canvas
import CanvasRPC
import LanguageModels
import Queries
import QueryLanguage
import QueryTranslation

// QueryCommands: the command line's side of queries. `canvas query` answers a query (the query
// language, Queries' engine) about the whole file of the board it names, or, with --ask, a question
// in English that the app's language model writes the query for (QueryTranslation's translator); `canvas
// query-vocabulary` says what this app's queries can name.
//
// A language on Automation (its commands), Queries (the engine), QueryTranslation (--ask) and the
// wire, since the answer is built as the wire's JSON, off the main actor (QueryOutput). It declares
// no point, and knows no shipped kind: --ask's system prompt is QueryTranslationPlugin's (a text file
// of the product's, whose examples name the shipped kinds), and its help writes <kind> and <title>.

extension PluginID {
    public static let queryCommands: PluginID = "query-commands"
}

/// `canvas query` and `canvas query-vocabulary`. Every plugin list with it needs `AutomationPlugin`,
/// and `QueriesPlugin` (without it both answer `no_queries`); `--ask` needs `QueryTranslationPlugin`
/// and `LanguageModelsPlugin` too (without them, `no_model`).
public struct QueryCommandsPlugin: ListedPlugin {
    public init() {}

    public var id: PluginID { .queryCommands }

    public func register(into registrar: inout PluginRegistrar) {
        let canvas = RPC.commandName
        registrar.automationCommand(
            "query", "Find the shapes of a file that a query matches, or that a question in English asks for.",
            discussion: """
                A query selects shapes as a CSS selector selects elements: by kind, by title in double quotes, by id \
                (#<id>), by attribute ([<attribute>=<value>]), by what's inside what and by what connects to what. It's \
                answered about every board of the file, and lists the shapes that match in file order (each with its \
                id, kind, title, board and attributes) and how many there are. It changes nothing. With --ask, the app \
                has Claude write the query from a question (with the key saved in Settings), runs it, and says what it \
                wrote. The language is taught by the canvas skill's reference/query.md, and its query-prompt.md is what \
                the app tells Claude; `\(canvas) query-vocabulary` lists what this app's queries can name. Queries hold \
                characters shells mangle: pass them on standard input (`\(canvas) query - <<'EOF'`).
                """,
            params: QueryParams.self, positionals: ["query"],
            // No kind by name: this plugin knows none, and the kinds are whatever's installed.
            examples: [
                CommandExample("\(canvas) query '<kind>'", "Every shape of a kind, on every board."),
                CommandExample(#"\#(canvas) query '"<title>" *'"#, "Every shape inside the one titled so, at any depth."),
                CommandExample("\(canvas) query --count '<kind>:top-level'", "How many of a kind are on the top board."),
                CommandExample("\(canvas) query - < query.txt", "Read the query from standard input."),
                CommandExample(#"\#(canvas) query --ask "which <kind>s mention <title>?""#, "Have Claude write the query, and run it."),
            ],
            runAsync: { (params: QueryParams, context: AutomationContext) async throws(AutomationError) -> JSON in
                try await query(params, in: context)
            })
        registrar.automationCommand(
            "query-vocabulary", "List what this app's queries can name: kinds and their attributes, edge types and words.",
            discussion: """
                Each kind, with what the app calls it, whether its shapes have titles (named, derived from what they \
                hold, or none), whether shapes can be inside its shapes (holdsShapes) and whether by a board of their \
                own (holdsBoard), and each attribute a query can test with what it takes; the edge types, each under \
                the one it's a kind of; and the pseudo-classes, the language's own and those this app's plugins add. \
                vocabulary is all of it as the block `\(canvas) query --ask` sends Claude.
                """,
            scope: .app, params: VocabularyParams.self,
            examples: [CommandExample("\(canvas) query-vocabulary", "Everything a query can name in this app.")],
            run: { (_: VocabularyParams, context: AutomationContext) throws(AutomationError) -> VocabularyAnswer in
                guard context.registry.answersQueries else { throw .noQueries }
                return VocabularyAnswer(QueryVocabulary(registry: context.registry))
            })
    }
}

// MARK: query

/// Runs `canvas query`: the query given, or the one the model writes for the question asked, on the
/// file of the board the request names, its answer built as JSON off the main actor.
@MainActor
func query(_ params: QueryParams, in context: AutomationContext) async throws(AutomationError) -> JSON {
    let asked = try params.asked()
    let editor = try context.board()
    guard let queries = editor.queries else { throw .noQueries }
    try params.checkFields(against: queries.vocabulary)
    switch asked {
    case .query(let text):
        let result = try await answer(text, with: queries, params)
        return await QueryOutput.json(consume result, countOnly: params.count)
    case .question(let question):
        guard let translator = editor.queryTranslator else { throw AutomationError(QueryTranslationError.noModel) }
        let outcome: AskOutcome
        do throws(QueryTranslationError) {
            outcome = try await translator.ask(question, limit: params.limit, countOnly: params.count, properties: params.listing)
        } catch {
            throw AutomationError(error)
        }
        return await QueryOutput.json(consume outcome, countOnly: params.count)
    }
}

/// A query's answer, or why it can't be answered, said where in the query that is.
@MainActor
private func answer(_ text: String, with queries: QueryState, _ params: QueryParams) async throws(AutomationError) -> QueryResult {
    do throws(QueryError) {
        // Edges are read as they settle: once answers still arriving have come, or `settleWait` has passed.
        return try await queries.run(QueryRequest(text, limit: params.limit, countOnly: params.count, properties: params.listing,
                                                  settle: QueryBudget.settleWait))
    } catch {
        throw AutomationError(error, in: text)
    }
}

extension AutomationError {
    /// No `QueriesPlugin`: nothing answers queries.
    static var noQueries: AutomationError { AutomationError("This app can't answer queries.", reason: "no_queries") }
}

extension AutomationError {
    /// A question's refusal as the command line reports it: the model's failures with a hint to save
    /// a key or try again, an unusable answer with where in the query it went wrong, and every other
    /// in its own reason and message.
    init(_ error: QueryTranslationError) {
        let yourself = "the canvas skill's query-prompt.md"
        switch error {
        case .noQueries:
            self.init(error.message, reason: error.reason)
        case .noModel:
            self.init(error.message, reason: error.reason,
                      hint: "Write the query yourself: \(yourself) is the guidance the app gives Claude.")
        case .model(let failure, _):
            if failure == .noKey || failure == .unauthorized {
                self.init(error.message, reason: error.reason,
                          hint: "Save an Anthropic API key in Infinite Canvas › Settings… (⌘,), or write the query yourself: \(yourself).")
            } else {
                self.init(error.message, reason: error.reason,
                          hint: failure.isTransient ? "Try again in a moment, or write the query yourself." : "Write the query yourself.",
                          details: ["transient": .bool(failure.isTransient)])
            }
        case .declined, .cancelled:
            self.init(error.message, reason: error.reason)
        case .unanswerable:
            self.init(error.message, reason: error.reason,
                      hint: "Queries find shapes by what they are, what's inside what and what connects to what; not where they are, how they look, or sums.")
        case .unusable(_, let query, let refusal):
            let place = refusal.flatMap { $0.located(in: query, quoting: QueryOutput.quoted) }
            self.init(error.message, reason: error.reason, hint: "Ask more specifically, or write the query yourself.",
                      line: place?.line, column: place?.column, length: place?.length, statement: place?.statement,
                      details: ["query": .string(query)])
        case .tooSlow:
            self.init(error.message, reason: error.reason, hint: "Ask again, or write the query yourself.")
        case .refused(let refusal):
            self.init(refusal, in: nil)
        }
    }
}
