import Automation
import Canvas
import CanvasRPC
import Foundation
import LanguageModels
import Queries
import QueryLanguage

/// `--ask`: a question in English, turned into a query by the editor's language model, and run.
///
/// On the main actor, awaiting, never holding it: the command's deadline (`AskStyle.deadline`) and
/// the end of the time for a second try (`AskStyle.repairBefore`) are armed on the editor's
/// scheduler as it starts; the request is assembled (`AskRequest`: where the person is and the
/// titles, each a query run, off the main actor); the model is asked; its answer read (`parse`); the
/// query it wrote run (`QueryState.run`, which checks it first). A refusal of the query, or an answer
/// of several lines whose last isn't a query, is sent back once, with the refusal, if it comes before
/// the mark; a second refusal is an unusable answer. When the deadline comes, whatever it stops says
/// why: a model call, `model_failed` (timed out); a query run or the request's assembly, `too_slow`.
public struct QueryAsking: Sendable {
    /// The system prompt.
    public let system: String
    public let style: AskStyle

    public init(system: String, style: AskStyle = .shipped) {
        self.system = system
        self.style = style
    }

    /// Asks the editor's model to write a query for `question`, and runs it (listing as a query
    /// request says: `limit`, `countOnly`, `properties`). Refused `no_queries` without Queries,
    /// `no_model` without a model, `no_key`, `key_rejected` or `model_failed` for the model's own
    /// failures, `declined`, `unanswerable`, `unusable_answer`, `too_slow` past the deadline, and
    /// `cancelled` when the caller's task is.
    @MainActor
    public func ask(_ question: String, in editor: CanvasEditor, limit: Int = QueryBudget.rows, countOnly: Bool = false,
                    properties: QueryRequest.Properties = .all) async throws(AutomationError) -> AskOutcome {
        guard let queries = editor.queries else { throw .noQueries }
        guard let model = editor.languageModel else { throw .noModel }
        let bounds = AskBounds()
        let deadline = editor.scheduler.schedule(after: AskStyle.deadline) {
            bounds.timedOut = true
            bounds.cancel?()
        }
        let mark = editor.scheduler.schedule(after: AskStyle.repairBefore) { bounds.repairClosed = true }
        defer {
            deadline.cancel()
            mark.cancel()
        }
        let asking = self
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = QueryRequest("", limit: limit, countOnly: countOnly, properties: properties)
        // Its own task, so the deadline can stop whatever it's waiting on.
        let task = Task { @MainActor () -> Result<AskOutcome, AutomationError> in
            do throws(AutomationError) {
                return .success(try await asking.steps(question, queries: queries, model: model, listing: request, bounds: bounds))
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

    /// The request, the model's answers, and the queries they wrote, within `bounds`.
    @MainActor
    private func steps(_ question: String, queries: QueryState, model: any LanguageModel, listing: QueryRequest,
                       bounds: AskBounds) async throws(AutomationError) -> AskOutcome {
        let place: QueryWhere, titles: [QueryTitle]
        do throws(QueryError) {
            place = try await queries.whereThePersonIs(selectedLimit: AskStyle.selected)
            titles = try await queries.titles(for: question, limit: AskStyle.titles)
        } catch {
            throw bounds.timedOut ? .askTooSlow : AutomationError(error, in: nil)
        }
        var request = AskRequest.request(question: question, vocabulary: queries.vocabulary.text, where: place, titles: titles,
                                         system: system, style: style)
        var outcome = AskOutcome(question: question)
        var repaired: String?
        for attempt in 1...2 {
            let response: ModelResponse
            do throws(LanguageModelError) {
                response = try await model.respond(to: request)
            } catch {
                throw Self.failure(error, timedOut: bounds.timedOut)
            }
            outcome.inputTokens += response.inputTokens
            outcome.outputTokens += response.outputTokens
            // Asked when a query is refused, which may be well after it was written (its run).
            var again: Bool { attempt == 1 && !bounds.repairClosed }
            switch Self.parse(response) {
            case .declined:
                throw AutomationError("Claude declined", reason: "declined")
            case .unanswerable(let why):
                throw AutomationError("A query can't ask that" + (why.isEmpty ? "." : ": " + Self.sentence(why)), reason: "unanswerable",
                                      hint: "Queries find shapes by what they are, what's inside what and what connects to what; not where they are, how they look, or sums.")
            case .unusable(let what, let repair):
                let written = Self.read(response.text)
                outcome.answers.append(written)
                guard again, let repair else { throw .unusable(what + ".", query: written) }
                repaired = "Claude's first answer wasn't a query on one line; this is its second."
                request = AskRequest.repairing(request, answer: response.text, error: repair)
            case .query(let text):
                outcome.answers.append(Self.read(response.text))
                var asked = listing
                asked.text = text
                do throws(QueryError) {
                    outcome.result = try await queries.run(asked)
                    if let repaired { outcome.result.warnings.insert(QueryWarning(.repaired, repaired), at: 0) }
                    return outcome
                } catch {
                    if bounds.timedOut { throw .askTooSlow }
                    guard error.isRefusal else { throw AutomationError(error, in: nil) }
                    guard again else { throw .unusable(AskRequest.said(error), query: text, refusal: error) }
                    repaired = "Claude's first query was refused (\(error.reason.rawValue)); this is its second."
                    request = AskRequest.repairing(request, answer: response.text, error: AskRequest.refusal(of: text, error))
                }
            }
        }
        // The loop returns or throws on its second pass.
        throw .unusable("it gave no query.", query: outcome.answers.last ?? "")
    }

    // MARK: Reading the answer

    /// An answer, as `--ask` reads it.
    public enum Answer: Equatable, Sendable {
        /// A query to run.
        case query(String)
        /// `UNANSWERABLE`, and why (empty when it doesn't say).
        case unanswerable(String)
        /// It declined to answer (a refusal).
        case declined
        /// No query: what's wrong with it, in a fragment, and what to tell the model for a second try;
        /// nil when a second try won't help.
        case unusable(String, repair: String?)
    }

    /// Reads an answer. A stop other than the end of its turn is unusable (cut off, or stopped
    /// early), or it declined. The text is trimmed and unwrapped (`ModelAnswer.unwrapped`: fence
    /// lines, lone tag lines, `<query>` tags), and of one pair of backticks, or a fence, around it on
    /// one line. A first word `UNANSWERABLE`, in any case, with or without a colon, is unanswerable,
    /// with what follows; nothing is unusable; one line is the query.
    ///
    /// More than one line with anything on them is most often reasoning, then the query on the last
    /// line (a line in one pair of backticks read without them): a last line that starts
    /// `UNANSWERABLE` is unanswerable; the lines joined by spaces, when they read as a query and some
    /// line alone doesn't, are one query written over several; else the last line, when it reads as
    /// a query (`SelectorList(parsing:)`: the words and titles in it aren't looked up). A query with
    /// more written after it is never taken: it's as often one the model went on to take back
    /// ("Wait, let me reconsider…"). Else a second try is told to put the query on one line.
    public static func parse(_ response: ModelResponse) -> Answer {
        switch response.stopReason {
        case .endTurn: break
        case .refusal: return .declined
        case .maxTokens: return .unusable("its answer was cut off", repair: nil)
        default: return .unusable("it stopped before its answer was done", repair: nil)
        }
        let text = read(response.text)
        if let why = unanswerable(text) { return .unanswerable(why) }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard let only = lines.last else { return .unusable("it answered nothing", repair: nil) }
        guard lines.count > 1 else { return .query(only) }
        let unticked = lines.map(Self.unticked)
        let last = unticked[unticked.count - 1]
        if let why = unanswerable(last) { return .unanswerable(why) }
        let whole = unticked.joined(separator: " ")
        if readsAsQuery(whole), !unticked.allSatisfy(readsAsQuery) { return .query(whole) }
        if readsAsQuery(last) { return .query(last) }
        return .unusable("it wrote several lines, and the last isn't a query", repair: AskRequest.oneLine)
    }

    /// Whether text reads as a query, whatever it names.
    static func readsAsQuery(_ text: String) -> Bool {
        (try? SelectorList(parsing: text)) != nil
    }

    /// A line of one pair of backticks around it, as a model quotes a query in its reasoning.
    static func unticked(_ line: String) -> String {
        guard line.count > 2, line.hasPrefix("`"), line.hasSuffix("`"), !line.hasPrefix("``") else { return line }
        return String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
    }

    /// The text trimmed and unwrapped, and of one pair of backticks, or a fence, around it on one
    /// line. Over several lines, a backtick first and one last are most often two pairs, the first
    /// line's and the last's, which `unticked` takes off line by line.
    static func read(_ text: String) -> String {
        var text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fence = "```"
        if !text.contains(where: \.isNewline), text.count > 2 * fence.count, text.hasPrefix(fence), text.hasSuffix(fence) {
            text = String(text.dropFirst(fence.count).dropLast(fence.count))
        }
        text = ModelAnswer.unwrapped(text, tag: "query")
        if !text.contains(where: \.isNewline), text.count >= 2, text.hasPrefix("`"), text.hasSuffix("`") {
            text = String(text.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    /// What follows a first word `UNANSWERABLE` (any case, bold or not, a colon or a dash after it),
    /// on one line; nil when the first word is anything else.
    static func unanswerable(_ text: String) -> String? {
        let marks: Set<Character> = ["*", "_"]
        let start = text.drop { marks.contains($0) }
        let word = start.prefix { $0.isLetter }
        guard word.uppercased() == "UNANSWERABLE" else { return nil }
        let after: Set<Character> = ["*", "_", ":", "-", "–", "—", "."]
        let rest = start.dropFirst(word.count).drop { after.contains($0) || $0.isWhitespace }
        return rest.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Ends with a period, unless it ends a sentence already.
    static func sentence(_ text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }

    // MARK: The model's failures

    /// A model's failure as the command line reports it: no key, a key refused, any other failure
    /// (in the model's words, and whether trying again may work), or the command's own
    /// cancellation, which the deadline makes a timeout.
    static func failure(_ error: LanguageModelError, timedOut: Bool) -> AutomationError {
        let yourself = "the canvas skill's query-prompt.md"
        switch error {
        case .noKey, .unauthorized:
            return AutomationError(error.message, reason: error == .noKey ? "no_key" : "key_rejected",
                                   hint: "Save an Anthropic API key in Infinite Canvas › Settings… (⌘,), or write the query yourself: \(yourself).")
        case .cancelled where !timedOut:
            return .cancelled
        default:
            let failure = error == .cancelled ? .timedOut : error
            return AutomationError(failure.message, reason: "model_failed",
                                   hint: failure.isTransient ? "Try again in a moment, or write the query yourself." : "Write the query yourself.",
                                   details: ["transient": .bool(failure.isTransient)])
        }
    }
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

/// One `--ask`'s bounds: whether its deadline has passed or its time for a second try, and how to
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

extension AutomationError {
    /// No language model to ask.
    static var noModel: AutomationError {
        AutomationError("This app has no language model.", reason: "no_model",
                        hint: "Write the query yourself: the canvas skill's query-prompt.md is the guidance the app gives Claude.")
    }

    /// The command's task was cancelled (its client went, its board closed).
    static var cancelled: AutomationError { AutomationError("The command was cancelled.", reason: QueryError.Reason.cancelled.rawValue) }

    /// Past `AskStyle.deadline`, in a query run or the request's assembly.
    static var askTooSlow: AutomationError {
        AutomationError("Answering the question took more than \(Int(AskStyle.deadline.components.seconds)) seconds.",
                        reason: QueryError.Reason.tooSlow.rawValue, hint: "Ask again, or write the query yourself.")
    }

    /// The model's answer gave no query that works: what's wrong (a sentence), where in the query
    /// when it was refused, and what it wrote last (`details.query`).
    static func unusable(_ what: String, query: String, refusal: QueryError? = nil) -> AutomationError {
        let place = refusal.flatMap { $0.located(in: query, quoting: QueryOutput.quoted) }
        return AutomationError("Claude's query didn't work: \(what)", reason: "unusable_answer", hint: "Ask more specifically, or write the query yourself.",
                               line: place?.line, column: place?.column, length: place?.length, statement: place?.statement,
                               details: ["query": .string(query)])
    }
}
