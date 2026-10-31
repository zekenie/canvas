import Automation
import Canvas
import CanvasRPC
import DecisionModels
import Foundation
import LanguageRules
import Queries
import QueryLanguage

// DecisionCommands: the command line's side of decision models. `canvas decide` asks one yes-or-no question of every
// shape a query finds, each with what is around it (the state a rule sees of it, LanguageRules'), and lists them with
// how likely each is a yes, highest first. Nothing is stored and nothing on the board changes: it answers an agent's
// question, where a rule on a type is what a person keeps.
//
// On Automation (its commands), Queries (which shapes), DecisionModels (the model asked, through `editor.decisions`,
// which answers what it asked today from memory) and LanguageRules (what a shape's state is), and the wire, whose JSON
// the answer is. It declares no point, and knows no shipped kind.

extension PluginID {
    public static let decisionCommands: PluginID = "decision-commands"
}

/// `canvas decide`. Every plugin list with it needs `AutomationPlugin`; `QueriesPlugin` (without it, `no_queries`),
/// `DecisionModelsPlugin` (without it, `no_model`) and `LanguageRulesPlugin`, whose checks build a shape's state
/// (without it, `no_model` too: there is nothing to ask with).
public struct DecisionCommandsPlugin: ListedPlugin {
    public init() {}

    public var id: PluginID { .decisionCommands }

    public func register(into registrar: inout PluginRegistrar) {
        let canvas = RPC.commandName
        registrar.automationCommand(
            "decide", "Ask one yes-or-no question of every shape a query finds, and list how likely each is a yes.",
            discussion: """
                The query (the canvas skill's reference/query.md) says which shapes; each is asked the question on its \
                own, with what it is and what is around it (its types and their words, where it is, what's beside it, \
                its edges, an arrow's ends) as a rule on a type sees it, by the app's decision model (TypeSafe's Jev, with \
                the key saved in Settings). The rows list each shape's id, title and the probability of yes, highest \
                first. Nothing is stored and nothing on the board changes; the same question of the same shape is \
                answered from memory the rest of the day. Questions hold characters shells mangle: pass the query on \
                standard input (`\\(canvas) decide - "<question>" <<'EOF'`).
                """,
            params: DecideParams.self, positionals: ["query", "question"],
            examples: [
                CommandExample(#"\#(canvas) decide '<kind>' "Does it say when it is due?""#, "Every shape of a kind, asked one question."),
                CommandExample(#"\#(canvas) decide --limit 10 ':is-a("<type>")' "Is it about money?""#, "The first ten shapes of a type."),
            ],
            runAsync: { (params: DecideParams, context: AutomationContext) async throws(AutomationError) -> JSON in
                try await decide(params, in: context)
            })
    }
}

/// Runs `canvas decide`: the shapes the query finds (at most `limit`, in file order), each asked the question with its
/// state, a few at once, the rows highest yes first.
@MainActor
func decide(_ params: DecideParams, in context: AutomationContext) async throws(AutomationError) -> JSON {
    let question = try params.asked()
    let editor = try context.board()
    guard let queries = editor.queries else { throw .noQueries }
    guard let decisions = editor.decisions, let checks = editor.ruleChecks else { throw .noDecisionModel }
    let result: QueryResult
    do throws(QueryError) {
        // As `canvas query` waits: for answers still arriving (a stand-in's edges), once they've come or a while has passed.
        result = try await queries.run(QueryRequest(params.query, limit: params.limit, properties: .none, settle: QueryBudget.settleWait))
    } catch {
        throw AutomationError(error, in: params.query)
    }
    let shapes = result.rows.map { (id: $0.id, title: $0.title) }
    let states = await checks.states(of: shapes.map(\.id))
    let asks = shapes.compactMap { shape in states[shape.id].map { (shape, DecideStyle.request(state: $0, question: question)) } }
    var answers: [ShapeID: DecisionAnswers] = [:]
    var failure: DecisionModelError?
    let requests = asks.map(\.1)
    /// Asks about the shape at `index`.
    let asking = { (index: Int) -> @MainActor () async -> (Int, Result<DecisionAnswers, DecisionModelError>) in
        let request = requests[index]
        return { @MainActor in
            do throws(DecisionModelError) {
                return (index, .success(try await decisions.decide(request)))
            } catch {
                return (index, .failure(error))
            }
        }
    }
    await withTaskGroup(of: (Int, Result<DecisionAnswers, DecisionModelError>).self) { group in
        var next = 0
        while next < min(DecideStyle.atOnce, requests.count) {
            group.addTask(operation: asking(next))
            next += 1
        }
        while let (index, outcome) = await group.next() {
            switch outcome {
            case .success(let answer): answers[asks[index].0.id] = answer
            case .failure(let error):
                // The first failure is the answer: every other call would fail the same way, or the person asked again.
                if failure == nil { failure = error }
                group.cancelAll()
            }
            if failure == nil, next < requests.count {
                group.addTask(operation: asking(next))
                next += 1
            }
        }
    }
    if let failure { throw AutomationError(failure) }
    let rows = asks.compactMap { shape, _ -> (id: ShapeID, title: String?, yes: Double)? in
        answers[shape.id]?.yes[DecideStyle.questionID].map { (shape.id, shape.title, $0) }
    }
    // Highest first; equal ones in file order, as the query found them.
    let order = Dictionary(uniqueKeysWithValues: shapes.enumerated().map { ($1.id, $0) })
    let sorted = rows.sorted { $0.yes != $1.yes ? $0.yes > $1.yes : (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
    var answer: [String: JSON] = [
        "query": .string(result.query),
        "question": .string(question),
        "count": .number(Double(sorted.count)),
        "rows": .array(sorted.map { row in
            var item: [String: JSON] = ["id": .string(row.id.description), "yes": .number(DecideStyle.rounded(row.yes))]
            if let title = row.title { item["title"] = .string(title) }
            return .object(item)
        }),
    ]
    if let model = answers.values.first?.model { answer["model"] = .string(model) }
    if result.count > shapes.count {
        answer["warnings"] = .array([.object(["reason": "limited", "message": .string(DecideStyle.limited(asked: shapes.count, of: result.count))])])
    }
    return .object(answer)
}

/// What `canvas decide` sends and says.
enum DecideStyle {
    /// The question's id in each request.
    static let questionID = "q"
    /// How many shapes are asked about at once.
    static let atOnce = 8
    /// The question as it's asked of a shape's state: the prototype's framing, "Judging from the state, does …?".
    static func request(state: JSONValue, question: String) -> DecisionRequest {
        DecisionRequest(state: state, questions: [DecisionQuestion(id: questionID, asks: "Judging from the state, " + continued(question))])
    }

    /// A question as it goes on after the framing's comma: its first word lower-case where it's one a yes-or-no question
    /// starts with ("Does", "Is"), else as written (a name, "I").
    static func continued(_ question: String) -> String {
        let first = question.prefix { $0.isLetter }
        guard openers.contains(first.lowercased()), first.dropFirst().allSatisfy(\.isLowercase) else { return question }
        return first.lowercased() + question.dropFirst(first.count)
    }

    /// The words a yes-or-no question starts with.
    static let openers: Set<String> = ["does", "do", "did", "is", "are", "was", "were", "has", "have", "had", "can", "could", "should", "would",
                                       "will", "may", "might", "must", "shall"]

    /// A probability as the rows say it: to two places, as the model's answers mean no more.
    static func rounded(_ probability: Double) -> Double { (probability * 100).rounded() / 100 }

    static func limited(asked: Int, of count: Int) -> String {
        "Asked about \(asked) of the \(count) shapes the query found: --limit asks about more."
    }
}

extension AutomationError {
    /// No decision model, or nothing to build a shape's state with.
    static var noDecisionModel: AutomationError {
        AutomationError("This app has no decision model.", reason: "no_model", hint: "Ask with canvas query, which needs none, or ask the user.")
    }

    /// A decision model's failure as the command line reports it: a key wanted with where to save one, a failure trying
    /// again may mend said so.
    init(_ error: DecisionModelError) {
        switch error.failure {
        case .noKey:
            self.init(error.message, reason: "no_key", hint: "Save a \(error.provider) API key in Infinite Canvas › Settings… (⌘,).")
        case .notSignedIn:
            self.init(error.message, reason: "not_signed_in", hint: "Sign in to \(error.provider) in Infinite Canvas › Settings… (⌘,).")
        case .unauthorized:
            self.init(error.message, reason: "key_rejected", hint: "Save a working \(error.provider) API key in Infinite Canvas › Settings… (⌘,).")
        case .cancelled:
            self.init(error.message, reason: "cancelled")
        default:
            self.init(error.message, reason: "model_failed", hint: error.isTransient ? "Try again in a moment." : nil,
                      details: ["transient": .bool(error.isTransient)])
        }
    }
}
