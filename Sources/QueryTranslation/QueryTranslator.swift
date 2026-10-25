import Canvas
import Foundation
import LanguageModels
import Queries
import QueryLanguage

// QueryTranslation: English into a query, for the command line and the app alike. The editor's
// language model is asked to write a query for a question (`AskRequest`: the system prompt, the
// vocabulary, where the person is, the titles), its answer is read (`AskAnswer`), and the query it
// wrote is run; a refusal is sent back once. `canvas query --ask` is its first caller (QueryCommands
// maps its errors to the wire's); it knows no command and no shape.
//
// A surface: the editor's model (LanguageModels) and the engine (Queries) are surfaces, and the
// system prompt comes from its init (the product's, a text file, whose examples name the shipped kinds).

extension PluginID {
    public static let queryTranslation: PluginID = "query-translation"
}

extension QueryWarning.Reason {
    /// `--ask`'s: the model's first query was refused, or wasn't one, and the answer is its second's.
    public static let repaired = QueryWarning.Reason(rawValue: "repaired")
}

/// What `--ask` did: the question, the answer to the query the model wrote (with the `repaired`
/// warning first when that was its second), what the model wrote each time it was asked (read:
/// trimmed and unwrapped), and the tokens it took in and wrote, over both.
public struct AskOutcome: Sendable {
    public var question: String
    public var result: QueryResult
    public var answers: [String]
    public var inputTokens: Int
    public var outputTokens: Int

    init(question: String) {
        self.question = question
        result = QueryResult(query: "", count: 0, rows: [], warnings: [])
        answers = []
        inputTokens = 0
        outputTokens = 0
    }

    /// Whether the answer is the model's second query.
    public var isRepaired: Bool { result.warnings.contains { $0.reason == .repaired } }
}

/// Why a question wasn't answered. `reason` is the word an agent branches on, `message` what to say
/// for a person; hints, which are the command line's, are not here.
public enum QueryTranslationError: Error, Sendable, Equatable {
    /// No `QueriesPlugin`.
    case noQueries
    /// No `LanguageModelsPlugin`.
    case noModel
    /// The model failed (a timeout, with `timedOut`, is the deadline's); never `.cancelled`, which is
    /// its own case here.
    case model(LanguageModelError, timedOut: Bool)
    /// The model declined to answer.
    case declined
    /// The model said no query can ask that, and why (empty when it doesn't say).
    case unanswerable(String)
    /// The answer gave no query that works: what's wrong (a sentence), what the model wrote last, and
    /// the engine's refusal when it was the query's.
    case unusable(String, query: String, refusal: QueryError?)
    /// Past `AskStyle.deadline`, in a query run or the request's assembly.
    case tooSlow
    /// The caller's task was cancelled.
    case cancelled
    /// The engine refused something no second try mends (a closed file, no Topology).
    case refused(QueryError)

    /// `no_queries`, `no_model`, `no_key`, `key_rejected`, `model_failed`, `declined`, `unanswerable`,
    /// `unusable_answer`, `too_slow`, `cancelled`, or the engine's own.
    public var reason: String {
        switch self {
        case .noQueries: "no_queries"
        case .noModel: "no_model"
        case .model(let error, _): error == .noKey ? "no_key" : error == .unauthorized ? "key_rejected" : "model_failed"
        case .declined: "declined"
        case .unanswerable: "unanswerable"
        case .unusable: "unusable_answer"
        case .tooSlow: QueryError.Reason.tooSlow.rawValue
        case .cancelled: QueryError.Reason.cancelled.rawValue
        case .refused(let error): error.reason.rawValue
        }
    }

    /// What to say: the model's own words for its failures ("No API key", "Rate limited").
    public var message: String {
        switch self {
        case .noQueries: "This app can't answer queries."
        case .noModel: "This app has no language model."
        case .model(let error, _): error.message
        case .declined: "Claude declined"
        case .unanswerable(let why): "A query can't ask that" + (why.isEmpty ? "." : ": " + AskAnswer.sentence(why))
        case .unusable(let what, _, _): "Claude's query didn't work: \(what)"
        case .tooSlow: "Answering the question took more than \(Int(AskStyle.deadline.components.seconds)) seconds."
        case .cancelled: "The command was cancelled."
        case .refused(let error): error.message
        }
    }
}

/// Who a translated query is for.
public enum TranslationContext: Sendable {
    /// A person asking, whose query is run at once (`--ask`): it may use what the person has selected
    /// and the board they're looking at.
    case person
    /// A person asking which of the shapes they have selected the question picks out, whose query's answer is
    /// kept to those (the command bar's `/query` on a selection): as `.person`, and what the model is told of
    /// where the person is says so.
    case selection
    /// A query that is stored and run later without the person (a reference's): the selection is left
    /// out of what the model is told, every word that reads the editor is left out of the vocabulary,
    /// one rule line says so, and the query must read only the file.
    case reference
}

/// What `translate` made: the query, as the language writes it (canonical, checked, its titles
/// found), what the model wrote each time it was asked (read: trimmed and unwrapped), the tokens it
/// took in and wrote over both, and whether the query is its second.
public struct TranslatedQuery: Sendable, Equatable {
    public var query: String
    public var answers: [String]
    public var inputTokens: Int
    public var outputTokens: Int
    public var repaired: Bool
}

/// One editor's translator of English into queries: asks its language model for a query for some
/// words (`translate`), and, for `--ask`, runs it (`ask`).
///
/// On the main actor, awaiting, never holding it: the deadline (`AskStyle.deadline`) and the end of
/// the time for a second try (`AskStyle.repairBefore`) are armed on the editor's scheduler as it
/// starts; the request is assembled (`AskRequest`: where the person is and the titles, each a query
/// run, off the main actor); the model is asked; its answer read (`AskAnswer.parse`); the query it
/// wrote validated: `ask` runs it (`QueryState.run`, which checks it first), `translate` checks it,
/// for a stored query that reads only the file, and that the titles and ids in it are the file's,
/// and runs nothing. A refusal of the query, or an answer of several lines whose last isn't a query,
/// is sent back once, with the refusal, if it comes before the mark; a second refusal is an unusable
/// answer. When the deadline comes, whatever it stops says why: a model call, `model_failed` (timed
/// out); a query run or the request's assembly, `too_slow`.
@MainActor
public final class QueryTranslator {
    /// The system prompt.
    public let system: String
    /// The one rule line added to it for a stored query (`TranslationContext.reference`).
    public let referenceRule: String
    public let style: AskStyle
    /// Weak: a question in flight never keeps a closed file's editor alive. Nor does a call hold it
    /// in a local across its awaits: what a question needs of it is taken at once (`inputs(for:)`), so
    /// the editor can go while a model call is out, and what cancels with it stops that call.
    private weak var editor: CanvasEditor?

    init(system: String, referenceRule: String, style: AskStyle, editor: CanvasEditor) {
        self.system = system
        self.referenceRule = referenceRule
        self.style = style
        self.editor = editor
    }

    /// What a question needs of the editor, taken at once: its queries, its model, its scheduler and what
    /// plugins tell of the file for this question (`QueryAskFacts`: each asked once, in the registry's order,
    /// on the main actor, with the editor and the question), none of which holds the editor, so the call that
    /// took them doesn't either.
    private func inputs(for question: String) throws(QueryTranslationError)
        -> (queries: QueryState, model: any LanguageModel, scheduler: any Scheduler, facts: [(tag: String, text: String)]) {
        guard let editor else { throw .cancelled }
        guard let queries = editor.queries else { throw .noQueries }
        guard let model = editor.languageModel else { throw .noModel }
        let facts = editor.registry.contributions(to: QueryAskFacts.self).map { (tag: $0.value.tag, text: $0.value.text(for: editor, question: question)) }
        return (queries, model, editor.scheduler, facts)
    }

    /// Asks the editor's model to write a query for `question`, and runs it (listing as a query
    /// request says: `limit`, `countOnly`, `properties`). Refused `noQueries` without Queries,
    /// `noModel` without a model, `model` for the model's own failures, `declined`, `unanswerable`,
    /// `unusable`, `tooSlow` past the deadline, and `cancelled` when the caller's task is.
    public func ask(_ question: String, limit: Int = QueryBudget.rows, countOnly: Bool = false,
                    properties: QueryRequest.Properties = .all) async throws(QueryTranslationError) -> AskOutcome {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let (queries, model, scheduler, facts) = try inputs(for: question)
        let translator = self
        // What `canvas query` asks: edges are read once the answers they wait on have come.
        let request = QueryRequest("", limit: limit, countOnly: countOnly, properties: properties, settle: QueryBudget.settleWait)
        return try await bounded(on: scheduler) { (bounds: AskBounds) async throws(QueryTranslationError) -> AskOutcome in
            let talk = try await translator.converse(question, context: .person, queries: queries, model: model, facts: facts, bounds: bounds) { (text: String) async throws(QueryError) -> QueryResult in
                var asked = request
                asked.text = text
                return try await queries.run(asked)
            }
            var outcome = AskOutcome(question: question)
            outcome.result = talk.checked
            if let repaired = talk.repaired { outcome.result.warnings.insert(QueryWarning(.repaired, repaired), at: 0) }
            outcome.answers = talk.answers
            outcome.inputTokens = talk.inputTokens
            outcome.outputTokens = talk.outputTokens
            return outcome
        }
    }

    /// Asks the editor's model to write a query for `words`, and checks it without running it: the
    /// same pipeline as `ask` (the request, the prompt, the model, the 55 s deadline, the second try
    /// before 40 s), validated three ways, each refusal going into the one second try: the query
    /// reads and resolves (`QueryState.check`); in `.reference` context it reads only the file (the
    /// words that read the editor are refused, naming the first); and the titles and ids in it are
    /// the file's (`checkNames`), so a wrong title is repaired, never returned. Nothing is evaluated.
    /// Refused as `ask` is.
    public func translate(_ words: String, about context: TranslationContext = .person) async throws(QueryTranslationError) -> TranslatedQuery {
        let words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        let (queries, model, scheduler, facts) = try inputs(for: words)
        let translator = self
        do throws(QueryTranslationError) {
            return try await bounded(on: scheduler) { (bounds: AskBounds) async throws(QueryTranslationError) -> TranslatedQuery in
                let talk = try await translator.converse(words, context: context, queries: queries, model: model, facts: facts, bounds: bounds) { (text: String) async throws(QueryError) -> String in
                    let plan = try context == .reference ? queries.checkStored(text) : queries.check(text)
                    if let refusal = await queries.checkNames(plan) { throw refusal }
                    return plan.canonical
                }
                return TranslatedQuery(query: talk.checked, answers: talk.answers, inputTokens: talk.inputTokens, outputTokens: talk.outputTokens,
                                       repaired: talk.repaired != nil)
            }
        } catch {
            // A task cancelled while a name was being checked is a cancellation, whatever it was in.
            if case .refused(let refusal) = error, refusal.reason == .cancelled { throw .cancelled }
            throw error
        }
    }

    /// Runs `work` in a task of its own with the deadline and the mark armed on the editor's
    /// scheduler (and let go of with it), which the deadline can stop whatever it's waiting on.
    private func bounded<Answer: Sendable>(on scheduler: any Scheduler, _ work: @escaping @MainActor (AskBounds) async throws(QueryTranslationError) -> Answer)
        async throws(QueryTranslationError) -> Answer {
        let bounds = AskBounds()
        let deadline = scheduler.schedule(after: AskStyle.deadline) {
            bounds.timedOut = true
            bounds.cancel?()
        }
        let mark = scheduler.schedule(after: AskStyle.repairBefore) { bounds.repairClosed = true }
        defer {
            deadline.cancel()
            mark.cancel()
        }
        let task = Task { @MainActor () -> Result<Answer, QueryTranslationError> in
            do throws(QueryTranslationError) {
                return .success(try await work(bounds))
            } catch {
                return .failure(error)
            }
        }
        bounds.cancel = { task.cancel() }
        let outcome = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        bounds.cancel = nil
        return try outcome.get()
    }

    /// What `converse` came to: what the validation made of the query, what the model wrote each
    /// time, the tokens, and why the answer is a second try's (nil when it isn't).
    private struct Talk<Checked: Sendable>: Sendable {
        var checked: Checked
        var answers: [String] = []
        var inputTokens = 0
        var outputTokens = 0
        var repaired: String?
    }

    /// The request, the model's answers, and the query each wrote, validated by `validate`, within
    /// `bounds`.
    private func converse<Checked: Sendable>(_ question: String, context: TranslationContext, queries: QueryState, model: any LanguageModel,
                                             facts: [(tag: String, text: String)], bounds: AskBounds, validate: (String) async throws(QueryError) -> Checked)
        async throws(QueryTranslationError) -> Talk<Checked> {
        let place: QueryWhere, titles: [QueryTitle]
        do throws(QueryError) {
            place = try await queries.whereThePersonIs(selectedLimit: context == .reference ? 0 : AskStyle.selected)
            titles = try await queries.titles(for: question, limit: AskStyle.titles)
        } catch {
            throw bounds.timedOut ? .tooSlow : .refused(error)
        }
        let reference = context == .reference
        let prompt = reference && !referenceRule.isEmpty ? system + "\n" + referenceRule : system
        let vocabulary = reference ? queries.vocabulary.textForStoredQueries : queries.vocabulary.text
        var request = AskRequest.request(question: question, vocabulary: vocabulary, where: place, titles: titles, system: prompt, style: style,
                                         selection: !reference, narrowing: context == .selection, facts: facts)
        var tokens = (input: 0, output: 0), answers: [String] = []
        var repaired: String?
        for attempt in 1...2 {
            let response: ModelResponse
            do throws(LanguageModelError) {
                response = try await model.respond(to: request)
            } catch {
                throw Self.failure(error, timedOut: bounds.timedOut)
            }
            tokens.input += response.inputTokens
            tokens.output += response.outputTokens
            // Asked when a query is refused, which may be well after it was written (its validation).
            var again: Bool { attempt == 1 && !bounds.repairClosed }
            switch AskAnswer.parse(response) {
            case .declined:
                throw .declined
            case .unanswerable(let why):
                throw .unanswerable(why)
            case .unusable(let what, let repair):
                let written = AskAnswer.read(response.text)
                answers.append(written)
                guard again, let repair else { throw .unusable(what + ".", query: written, refusal: nil) }
                repaired = "Claude's first answer wasn't a query on one line; this is its second."
                request = AskRequest.repairing(request, answer: response.text, error: repair)
            case .query(let text):
                answers.append(AskAnswer.read(response.text))
                do throws(QueryError) {
                    let checked = try await validate(text)
                    return Talk(checked: checked, answers: answers, inputTokens: tokens.input, outputTokens: tokens.output, repaired: repaired)
                } catch {
                    if bounds.timedOut { throw .tooSlow }
                    guard error.isRefusal else { throw .refused(error) }
                    guard again else { throw .unusable(AskRequest.said(error), query: text, refusal: error) }
                    repaired = "Claude's first query was refused (\(error.reason.rawValue)); this is its second."
                    request = AskRequest.repairing(request, answer: response.text, error: AskRequest.refusal(of: text, error))
                }
            }
        }
        // The loop returns or throws on its second pass.
        throw .unusable("it gave no query.", query: answers.last ?? "", refusal: nil)
    }

    /// A model's failure: its own cancellation, which the deadline makes a timeout; or the failure.
    private static func failure(_ error: LanguageModelError, timedOut: Bool) -> QueryTranslationError {
        if error == .cancelled, !timedOut { return .cancelled }
        return .model(error == .cancelled ? .timedOut : error, timedOut: timedOut)
    }
}

extension QueryTranslator: EditorService {}

extension CanvasEditor {
    /// The editor's translator of English into queries; nil without `QueryTranslationPlugin`.
    public var queryTranslator: QueryTranslator? { service(QueryTranslator.self) }
}

/// Lends every editor a `QueryTranslator`. Every plugin list with it needs `QueriesPlugin` and
/// `LanguageModelsPlugin` (without them it answers `noQueries` and `noModel`).
public struct QueryTranslationPlugin: ListedPlugin {
    let prompt: String
    let referenceRule: String
    let style: AskStyle

    /// `prompt` is the system prompt the model is asked with, and `referenceRule` the one line added
    /// to it when the query is stored and run later (`TranslationContext.reference`); `style` which
    /// model it asks, and how (`AskStyle.shipped` unless an evaluation tries another).
    public init(prompt: String, referenceRule: String, style: AskStyle = .shipped) {
        self.prompt = prompt
        self.referenceRule = referenceRule
        self.style = style
    }

    /// The product's translator: asked with the product's prompt and rule line, which are text
    /// files of its own (`Shipped/ask-prompt.txt` and `ask-rule.txt`, `ShippedText`), since their
    /// examples name the shipped kinds, edge types and words, which no module knows all of. The
    /// prompt is the file byte for byte; the rule is its one line, without the line break. Only an
    /// executable that is the product has them: anything else passes its own (`init(prompt:referenceRule:style:)`).
    public init() {
        guard let prompt = ShippedText.named(Self.promptFile), let rule = ShippedText.named(Self.ruleFile) else {
            preconditionFailure("QueryTranslationPlugin() reads Shipped/\(Self.promptFile).txt and \(Self.ruleFile).txt, which the build puts only in the product's executables: pass a prompt")
        }
        self.init(prompt: prompt, referenceRule: rule.trimmingCharacters(in: .newlines))
    }

    /// The product's files this plugin reads (`Shipped/<name>.txt`).
    public nonisolated static let promptFile = "ask-prompt"
    public nonisolated static let ruleFile = "ask-rule"

    public var id: PluginID { .queryTranslation }

    public func register(into registrar: inout PluginRegistrar) {
        let prompt = prompt, referenceRule = referenceRule, style = style
        registrar.service { QueryTranslator(system: prompt, referenceRule: referenceRule, style: style, editor: $0) }
    }
}

/// One question's bounds: whether its deadline has passed or its time for a second try, and how to
/// stop what it's waiting on.
@MainActor
private final class AskBounds {
    var timedOut = false
    var repairClosed = false
    var cancel: (@Sendable () -> Void)?
}

extension QueryError {
    /// Whether it's the query's fault, which a second try may mend: anything but a cancellation, a
    /// closed file or no Topology.
    var isRefusal: Bool {
        switch reason {
        case .cancelled, .boardClosed, .noTopology: false
        default: true
        }
    }
}
