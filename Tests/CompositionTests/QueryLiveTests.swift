import AppKit
@_spi(Host) import Canvas
import Foundation
import LanguageModels
import Queries
import QueryTranslation
import Selection
import ShippedTesting
import TestKit

// `--ask` against the real model (QUERY_LIVE=1 only: test.sh never sets it, and nothing else here
// reaches the network): each case of scripts/query-prompts/cases.tsv opened on its file with the
// shipped plugins, its board shown and its shapes selected, its question asked as the command asks
// it (`QueryTranslator` with `QueryPrompt.system`, the editor's model `AnthropicModel` with the key
// Settings saves, the repair turn, the command's deadlines on real time), and its answer scored by
// the set of shapes it matches, so any query that finds them passes. scripts/query-prompts/README.md
// says how to run it and read what it prints. Without QUERY_LIVE, only the cases' own check runs:
// each case's reference query, run on its file, finds what the case expects.

/// Where the cases are, and where a round's rows go, from the repository's root (where tests run).
let queryCasesPath = "scripts/query-prompts/cases.tsv"
let queryResultsPath = "scripts/query-prompts/results.tsv"

/// A case of the evaluation: a row of cases.tsv.
struct QueryEvalCase: Sendable {
    enum File: String, Sendable {
        case story
        case evalBoard = "eval-board"
        case fields
    }

    /// What a right answer is.
    enum Expected: Equatable, Sendable {
        /// Exactly these shapes, by title (every shape of it) or id; none for none.
        case shapes([String])
        /// `UNANSWERABLE`.
        case unanswerable
        /// `UNANSWERABLE`, or any query that's answered: a question that tries to steer the model.
        case unanswerableOrQuery
    }

    static let categories = ["kinds", "titles", "mentions", "inside", "direction", "transitive", "state", "combined", "unanswerable",
                             "robustness", "types"]

    let id: String
    let file: File
    let question: String
    /// The subboard whose board is shown (`in <title>` in the selection column); nil for the top board.
    let board: String?
    /// What's selected there, by title or id.
    let selected: [String]
    let expected: Expected
    let category: String
    /// A query that answers it, which the cases' check runs; nil for none (`-`).
    let reference: String?

    /// Names in a column: separated by ", "; `-` or empty for none.
    static func names(_ column: String) -> [String] {
        column == "-" || column.isEmpty ? [] : column.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }
    }
}

/// The cases, in the file's order; the test fails for a row it can't read.
@MainActor
func queryEvalCases() throws -> [QueryEvalCase] {
    let lines = try String(contentsOfFile: queryCasesPath, encoding: .utf8).split(separator: "\n").map(String.init)
    _ = try require(lines.first == "id\tfile\tquestion\tselection\texpected\tcategory\treference" ? true : nil, "\(queryCasesPath)'s header")
    return try lines.dropFirst().filter { !$0.isEmpty }.map { line in
        let cells = line.components(separatedBy: "\t")
        _ = try require(cells.count == 7 ? true : nil, "seven columns: \(line)")
        let file = try require(QueryEvalCase.File(rawValue: cells[1]), "a file, story or eval-board: \(line)")
        let selection = QueryEvalCase.names(cells[3])
        let board = selection.first { $0.hasPrefix("in ") }.map { String($0.dropFirst(3)) }
        let expected: QueryEvalCase.Expected = switch cells[4] {
        case "UNANSWERABLE": .unanswerable
        case "UNANSWERABLE or a query": .unanswerableOrQuery
        case "none": .shapes([])
        default: .shapes(QueryEvalCase.names(cells[4]))
        }
        return QueryEvalCase(id: cells[0], file: file, question: cells[2], board: board, selected: selection.filter { !$0.hasPrefix("in ") },
                             expected: expected, category: cells[5], reference: cells[6] == "-" ? nil : cells[6])
    }
}

/// A case's file opened as the app opens it, in an editor of the shipped plugins on real time, with
/// `model` as its model and its clipboard on `pasteboard`: the case's board shown (the story's
/// viewport) and its shapes selected. Throws, and the test fails, for a name its file doesn't have.
@MainActor
func openQueryCase(_ evalCase: QueryEvalCase, model: any LanguageModel, pasteboard: NSPasteboard, style: AskStyle = .shipped) async throws
    -> (editor: CanvasEditor, names: QueryCaseNames) {
    // The shipped list, asking in `style`.
    let plugins = ShippedPlugins.plugins(pasteboard: pasteboard, model: model).map { plugin in
        plugin.id == .queryTranslation ? QueryTranslationPlugin(prompt: QueryPrompt.system, referenceRule: QueryPrompt.referenceRule, style: style) : plugin
    }
    let registry = try Registry(plugins: plugins)
    let file = switch evalCase.file {
    case .story: QueryStory.file(in: registry)
    case .evalBoard: QueryEvalBoard.file(in: registry)
    case .fields: QueryFieldsBoard.file(in: registry)
    }
    let editor = CanvasEditor(registry: registry, file: file, scheduler: TaskScheduler())
    editor.viewportDidResize(to: QueryStory.viewport)
    let queries = try require(editor.queries)
    let names = QueryCaseNames(rows: try await queries.run(QueryRequest("*", limit: QueryBudget.maxRows, properties: .none)).rows)
    if let board = evalCase.board {
        let owner = try require(names.ids(board).first, "\(evalCase.id): no subboard \(board)")
        _ = try require(editor.showBoard(BoardID(owner: owner)) ? true : nil, "\(evalCase.id): \(board)'s board is shown")
    }
    let selected = try evalCase.selected.flatMap { try names.ids($0) }
    editor.selectedShapeIDs = selected
    expectEqual(editor.selectedShapeIDs, selected, "\(evalCase.id): what it selects is on the board shown")
    return (editor, names)
}

/// A file's shapes by name, as the cases write them: a title names every shape that has it; an id,
/// its shape. From the rows of the query `*`.
@MainActor
struct QueryCaseNames {
    let rows: [QueryRow]

    /// The shapes a name names; the test fails for one the file doesn't have.
    func ids(_ name: String) throws -> [ShapeID] {
        if let uuid = UUID(uuidString: name) {
            return [try require(rows.first { $0.id == ShapeID(uuid) }?.id, "no shape \(name)")]
        }
        let named = rows.filter { $0.title == name }.map(\.id)
        _ = try require(named.isEmpty ? nil : named, "no shape titled \(name)")
        return named
    }

    /// Shapes as the cases write them: by title, or by id when untitled.
    func describe(_ ids: [ShapeID]) -> String {
        let titles = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.title ?? $0.id.description) })
        return ids.isEmpty ? "none" : ids.map { titles[$0] ?? $0.description }.joined(separator: ", ")
    }
}

/// The model the evaluation asks, `AnthropicModel`, and what it answered each time it was asked.
@MainActor
final class RecordingModel: LanguageModel {
    let model: AnthropicModel
    /// Each call's answer, or its failure, in order.
    private(set) var calls: [Result<ModelResponse, LanguageModelError>] = []

    init(_ model: AnthropicModel) { self.model = model }

    func respond(to request: ModelRequest) async throws(LanguageModelError) -> ModelResponse {
        do throws(LanguageModelError) {
            let response = try await model.respond(to: request)
            calls.append(.success(response))
            return response
        } catch {
            calls.append(.failure(error))
            throw error
        }
    }
}

/// One run of a case: what the model wrote each time it was asked, whether its answer passed and
/// after a second try or not, what went wrong, how long the command took, the tokens both calls
/// took in and wrote, and how many times it was asked again after the API failed it.
struct QueryEvalRun: Sendable {
    let caseID: String
    let category: String
    let run: Int
    let answers: [String]
    let passed: Bool
    let repaired: Bool
    let note: String
    let milliseconds: Int
    let inputTokens: Int
    let outputTokens: Int
    var retries = 0

    var firstTry: Bool { passed && !repaired }
}

/// Whether a model call failed for the API's sake, not the question's: rate limited (the round's
/// own calls at once), overloaded, a server error, or no connection. A run that fails so is asked
/// again, as `scripts/schema-prompts/evals.py` asks again, since it says nothing of the prompt; a
/// timeout isn't, since the person would see it.
private func failedForTheAPI(_ call: Result<ModelResponse, LanguageModelError>) -> Bool {
    guard case .failure(let error) = call else { return false }
    switch error {
    case .rateLimited, .overloaded, .network: return true
    case .server(let status, _): return status >= 500
    default: return false
    }
}

/// How many times a run is asked again after the API failed it, and how long it waits before the
/// first (doubling each time).
private let apiRetries = 4
private let apiRetryWait: Duration = .seconds(2)

/// Asks a case's question `runs` times on its file, as `--ask` does, and scores each answer.
@MainActor
func runQueryCase(_ evalCase: QueryEvalCase, runs: Int, style: AskStyle) async -> [QueryEvalRun] {
    let pasteboard = NSPasteboard.withUniqueName()
    defer { pasteboard.releaseGlobally() }
    let recorder = RecordingModel(AnthropicModel())
    /// A failed run that asked nothing: the case's own fault.
    func broken(_ note: String) -> [QueryEvalRun] {
        [QueryEvalRun(caseID: evalCase.id, category: evalCase.category, run: 1, answers: [], passed: false, repaired: false,
                      note: note, milliseconds: 0, inputTokens: 0, outputTokens: 0)]
    }
    let opened: (editor: CanvasEditor, names: QueryCaseNames)
    do {
        opened = try await openQueryCase(evalCase, model: recorder, pasteboard: pasteboard, style: style)
    } catch {
        return broken("the case doesn't open: \(error)")
    }
    let names = opened.names
    var expected: Set<ShapeID>?
    if case .shapes(let listed) = evalCase.expected {
        do {
            expected = Set(try listed.flatMap { try names.ids($0) })
        } catch {
            return broken("its expected shapes aren't all in its file: \(error)")
        }
    }
    var done: [QueryEvalRun] = []
    for run in 1...max(runs, 1) {
        var retries = 0
        var before: Int, elapsed: Duration, outcome: Result<AskOutcome, any Error>
        repeat {
            if retries > 0 { try? await Task.sleep(for: apiRetryWait * (1 << (retries - 1))) }
            before = recorder.calls.count
            let start = ContinuousClock.now
            do {
                let translator = try require(opened.editor.queryTranslator)
                outcome = .success(try await translator.ask(evalCase.question, limit: QueryBudget.maxRows, properties: .none))
            } catch {
                outcome = .failure(error)
            }
            elapsed = ContinuousClock.now - start
            retries += 1
        } while retries <= apiRetries && (try? outcome.get()) == nil && recorder.calls[before...].contains(where: failedForTheAPI)
        retries -= 1
        let calls = recorder.calls[before...]
        // What it wrote, on one line, or how its call failed.
        let answers = calls.map { call in
            switch call {
            case .success(let response): response.text.replacingOccurrences(of: "\n", with: " ⏎ ").replacingOccurrences(of: "\t", with: " ")
            case .failure(let error): "(\(error.message))"
            }
        }
        // How `--ask` read each answer: its last UNANSWERABLE, or a query that's only the word the
        // question tried to make it write.
        let read = calls.map { (try? $0.get()).map(AskAnswer.parse) }
        var unanswerable = false, steered = false
        if case .unanswerable(_)?? = read.last { unanswerable = true }
        for answer in read {
            if case .query(let text)? = answer, text.trimmingCharacters(in: .punctuationCharacters).uppercased() == "DROP" { steered = true }
        }
        /// What the command did, when that isn't what was wanted.
        var said: String {
            switch outcome {
            case .success(let asked): "matched \(names.describe(asked.result.rows.map(\.id)))"
            case .failure(let error): "\(error)"
            }
        }
        let passed: Bool, note: String
        switch evalCase.expected {
        case .shapes:
            passed = (try? outcome.get()).map { Set($0.result.rows.map(\.id)) == expected } ?? false
            note = passed ? "" : said
        case .unanswerable:
            passed = unanswerable
            note = passed ? "" : said
        case .unanswerableOrQuery:
            passed = !steered && (unanswerable || (try? outcome.get()) != nil)
            note = steered ? "it wrote DROP" : passed ? "" : said
        }
        let responses = calls.compactMap { try? $0.get() }
        done.append(QueryEvalRun(caseID: evalCase.id, category: evalCase.category, run: run, answers: answers, passed: passed,
                                 repaired: calls.count > 1, note: note, milliseconds: Int(elapsed / .milliseconds(1)),
                                 inputTokens: responses.reduce(0) { $0 + $1.inputTokens },
                                 outputTokens: responses.reduce(0) { $0 + $1.outputTokens }, retries: retries))
    }
    return done
}

/// The cases a round has yet to ask, taken one at a time by the few asking at once, and the runs
/// they've done.
@MainActor
final class QueryEvalLine {
    private var waiting: ArraySlice<QueryEvalCase>
    var finished: [QueryEvalRun] = []

    init(_ cases: [QueryEvalCase]) { waiting = cases[...] }

    func take() -> QueryEvalCase? { waiting.popFirst() }
}

/// A share, as a whole percentage (for what's printed: the bar compares exactly, `atLeast`).
private func percent(_ part: Int, of whole: Int) -> Int { whole == 0 ? 0 : Int((Double(part) * 100 / Double(whole)).rounded()) }

/// Whether `part` is at least `share` percent of `whole`, exactly: 182 of 192 (94.8%) isn't 95%.
private func atLeast(_ share: Int, _ part: Int, of whole: Int) -> Bool { part * 100 >= share * whole }

/// The value `fraction` of the way through `values`, sorted (the nearest rank).
private func percentile(_ values: [Int], _ fraction: Double) -> Int {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    return sorted[min(sorted.count - 1, max(0, Int((fraction * Double(sorted.count)).rounded(.up)) - 1))]
}

/// A line of totals over some runs: how many passed on the first try and after the repair turn, how
/// many failed, how long the command took (p50, p90), and the tokens a run took in and wrote, on
/// average.
private func tally(_ runs: [QueryEvalRun]) -> String {
    let first = runs.filter(\.firstTry).count, passed = runs.filter(\.passed).count
    let latencies = runs.map(\.milliseconds)
    let tokensIn = runs.isEmpty ? 0 : runs.reduce(0) { $0 + $1.inputTokens } / runs.count
    let tokensOut = runs.isEmpty ? 0 : runs.reduce(0) { $0 + $1.outputTokens } / runs.count
    return "\(runs.count) runs, first try \(first) (\(percent(first, of: runs.count))%), after repair \(passed) (\(percent(passed, of: runs.count))%), "
        + "failed \(runs.count - passed); p50 \(percentile(latencies, 0.5)) ms, p90 \(percentile(latencies, 0.9)) ms; "
        + "mean tokens \(tokensIn) in, \(tokensOut) out"
}

@MainActor let queryLiveTests = Suite("Query prompt, live", [
    test("the cases: each opens on its file, and its reference query finds what it expects there") {
        let cases = try queryEvalCases()
        expect(cases.filter { $0.file == .story }.count >= 40 && cases.filter { $0.file == .evalBoard }.count >= 15, "about 45 and 15")
        expectEqual(Set(cases.map(\.id)).count, cases.count, "each case has an id of its own")
        for evalCase in cases {
            expect(QueryEvalCase.categories.contains(evalCase.category), "\(evalCase.id): no category \(evalCase.category)")
            let pasteboard = NSPasteboard.withUniqueName()
            defer { pasteboard.releaseGlobally() }
            let (editor, names) = try awaitResult { try await openQueryCase(evalCase, model: ScriptedLanguageModel(), pasteboard: pasteboard) }
            guard case .shapes(let listed) = evalCase.expected else {
                expect(evalCase.reference == nil, "\(evalCase.id): a question no query answers has no reference")
                continue
            }
            let expected = try listed.flatMap { try names.ids($0) }
            let reference = try require(evalCase.reference, "\(evalCase.id): a reference query")
            let queries = try require(editor.queries)
            let found = try awaitResult { try await queries.run(QueryRequest(reference, limit: QueryBudget.maxRows, properties: .none)) }
            expectEqual(Set(found.rows.map(\.id)), Set(expected),
                        "\(evalCase.id) \(reference): found \(names.describe(found.rows.map(\.id))), expected \(names.describe(expected))")
        }
    },

    test("with QUERY_LIVE=1: each case asked as --ask asks it, scored by the shapes its answer matches") {
        let environment = ProcessInfo.processInfo.environment
        guard environment["QUERY_LIVE"] == "1" else { return }
        guard AnthropicKeyStore.standard.hasKey else { return expect(false, "no key: save one in Infinite Canvas › Settings…") }
        let runs = max(Int(environment["QUERY_RUNS"] ?? "") ?? 3, 1)
        let jobs = max(Int(environment["QUERY_JOBS"] ?? "") ?? 4, 1)
        // The model --ask ships with, unless QUERY_MODEL names another.
        var style = environment["QUERY_MODEL"].flatMap { $0.isEmpty ? nil : AskStyle.named($0) } ?? AskStyle.shipped
        // QUERY_EFFORT: another effort than the model's style says (`low`, `medium`, `high`…); not for Haiku 4.5, which refuses one.
        if let effort = environment["QUERY_EFFORT"], !effort.isEmpty { style.effort = effort }
        let model = style.model ?? AnthropicModel.haiku
        let only = environment["QUERY_CASES"].map { Set($0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }) }
        let cases = try queryEvalCases().filter { only?.contains($0.id) ?? true }
        if let only { expectEqual(Set(cases.map(\.id)), only, "QUERY_CASES names cases there are") }
        let settings = [style.temperature.map { "temperature \($0)" }, "\(style.maxTokens) tokens", style.effort.map { "effort \($0)" },
                        style.fallbacks.map { "fallbacks \($0.rawValue)" }]
        print("── \(cases.count) cases × \(runs) runs on \(model) (\(settings.compactMap { $0 }.joined(separator: ", "))), \(jobs) at a time")

        // Each case on a file of its own, a few at a time; its runs one after another.
        let line = QueryEvalLine(cases)
        let workers = (0..<min(jobs, cases.count)).map { _ in
            Task { @MainActor in
                while let next = line.take() {
                    let done = await runQueryCase(next, runs: runs, style: style)
                    line.finished += done
                    print("   \(next.id): \(done.filter(\.passed).count) of \(done.count) passed")
                }
            }
        }
        let order = Dictionary(uniqueKeysWithValues: cases.enumerated().map { ($1.id, $0) })
        let all = try awaitResult(timeout: Double(cases.count * runs) * 70 + 60) { () async -> [QueryEvalRun] in
            for worker in workers { await worker.value }
            return line.finished
        }.sorted { (order[$0.caseID] ?? 0, $0.run) < (order[$1.caseID] ?? 0, $1.run) }

        // Each case: its runs, and for any that didn't pass first time, what the model wrote.
        print("── cases")
        for evalCase in cases {
            let own = all.filter { $0.caseID == evalCase.id }
            let latency = percentile(own.map(\.milliseconds), 0.5)
            print("\(evalCase.id) \(evalCase.category.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                + "\(own.filter(\.firstTry).count)/\(own.count) first try, \(own.filter { $0.passed && $0.repaired }.count) repaired, "
                + "\(own.filter { !$0.passed }.count) failed; p50 \(latency) ms  “\(evalCase.question)”")
            for run in own where !run.firstTry {
                let queries = run.answers.map { "`\($0)`" }.joined(separator: " then ")
                print("     run \(run.run) \(run.passed ? "repaired" : "FAILED"): \(queries)\(run.note.isEmpty ? "" : ": \(run.note)")")
            }
        }
        print("── by category")
        var categoriesPassing = true
        for category in QueryEvalCase.categories {
            let own = all.filter { $0.category == category }
            guard !own.isEmpty else { continue }
            print("\(category.padding(toLength: 12, withPad: " ", startingAt: 0)) \(tally(own))")
            if !atLeast(90, own.filter(\.passed).count, of: own.count) { categoriesPassing = false }
        }
        print("── all: \(tally(all))")
        let retried = all.filter { $0.retries > 0 }
        if !retried.isEmpty {
            print("── \(retried.count) runs asked again after the API failed them (\(retried.reduce(0) { $0 + $1.retries }) times in all)")
        }

        // The bar (scripts/query-prompts/README.md), held only on a round of every case: every run of
        // a case whose answer is UNANSWERABLE, or that tries to steer the model, passes.
        let refusing = Set(cases.filter { $0.expected == .unanswerable || $0.expected == .unanswerableOrQuery }.map(\.id))
        let passed = all.filter(\.passed).count, first = all.filter(\.firstTry).count
        let strict = all.filter { refusing.contains($0.caseID) }.allSatisfy(\.passed)
        let met = atLeast(95, passed, of: all.count) && atLeast(85, first, of: all.count) && categoriesPassing && strict
        print("── the bar (95% after repair, 85% first try, 90% each category, every run of the unanswerable and steering cases): "
            + (met ? "met" : "missed") + (only == nil ? "" : " (a subset: not held)"))
        if only == nil {
            expect(met, "the bar: \(passed) of \(all.count) after repair, \(first) first try, every category \(categoriesPassing ? "" : "not ")at 90%, "
                + "the unanswerable and steering cases \(strict ? "all" : "not all") passing")
        }

        // A row a run, for the rounds' record.
        if let round = environment["QUERY_EVAL_OUT"], !round.isEmpty {
            let header = "round\tcase\tmodel\trun\tfirst_try\trepaired\tpass\tquery\tsecond_query\tms\tinput_tokens\toutput_tokens\n"
            let rows = all.map { run in
                [round, run.caseID, model, "\(run.run)", run.firstTry ? "1" : "0", run.repaired ? "1" : "0", run.passed ? "1" : "0",
                 run.answers.first ?? "", run.answers.dropFirst().first ?? "", "\(run.milliseconds)", "\(run.inputTokens)", "\(run.outputTokens)"]
                    .joined(separator: "\t") + "\n"
            }.joined()
            let existing = (try? String(contentsOfFile: queryResultsPath, encoding: .utf8)) ?? ""
            try (existing.isEmpty ? header : existing).appending(rows).write(toFile: queryResultsPath, atomically: true, encoding: .utf8)
            print("── \(all.count) rows appended to \(queryResultsPath) as round \(round)")
        }
    },
])
