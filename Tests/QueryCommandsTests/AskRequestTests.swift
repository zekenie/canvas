import Automation
import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import LanguageModels
import Queries
import QueryCommands
import QueryLanguage
import QueryTranslation
import TestKit

// What `--ask` sends the model, exactly: the system prompt, and one message of tagged blocks (the
// question, the vocabulary, where the person is, the titles), a blank line between them, one with
// nothing to say left out; the second try's two more messages; and the model's settings, from
// `AskStyle`. Nothing else leaves the machine: no shape's text.

/// The `--ask` harness: the shelf, a scripted model, and what the person picked.
@MainActor func askHarness(_ model: ScriptedLanguageModel, desk: Desk = Desk(), askStyle: AskStyle = .shipped,
                           file: CanvasFile = shelf()) throws -> EditorHarness {
    try shelfHarness(commandPlugins(model: model, desk: desk, askStyle: askStyle), file: file)
}

@MainActor let askRequestTests = Suite("--ask's request", [
    test("the request: the system prompt, and the question, the vocabulary, the board and the titles, in that order") {
        let model = ScriptedLanguageModel(answers: ["chore"])
        let desk = Desk()
        desk.picked = [id(1), id(21)]
        let h = try askHarness(model, desk: desk)
        _ = try answered(["query", "--ask", "  Which chores are in the pantry?\n"], on: h)
        let request = try require(model.lastRequest)
        expectEqual(request.system, systemPrompt)
        expectEqual(request.maxTokens, 2_048)
        expectEqual(request.temperature, nil)
        expectEqual(request.model, "claude-sonnet-5-5", "the shipped style's model, not the editor's")
        expectEqual(request.effort, "low")
        expectEqual(request.fallbacks, .default)
        expectEqual(request.stopSequences, [])
        let vocabulary = try require(h.editor.queries).vocabulary.text
        // Titles sharing a word with the question first, then the board shown's, then the rest, each
        // in file order.
        let expected = """
            <question>
            Which chores are in the pantry?
            </question>

            <vocabulary>
            \(vocabulary)
            </vocabulary>

            <board>
            The person is looking at the top board. Selected: "Alpha" (chore), an untitled chore, #\(uuid(21)).
            </board>

            <titles>
            "Pantry" pocket
            "Alpha" chore
            "Beta" chore, in Pantry
            "Gamma" chore, in Pantry › Untitled Pocket
            </titles>
            """
        expectEqual(request.messages, [.user(expected)])
        expect(!request.messages[0].text.contains("abab"), "no shape's text leaves the machine")
    },
    test("where the person is: a board inside others by its path, a title as a query writes it, and past 20 selected, how many more") {
        let model = ScriptedLanguageModel()
        model.fallback = { _ in .success(ModelResponse(text: "chore")) }
        let desk = Desk()
        let shelved = shelf()
        let many = (100..<125).map { chore(id($0), caption: $0 == 100 ? #"Say "hi" \ bye"# : nil) }
        let file = CanvasFile(root: CanvasDocument(shapes: shelved.root.shapes + many), children: shelved.children)
        let h = try askHarness(model, desk: desk, file: file)
        @MainActor func board() throws -> String {
            _ = try answered(["query", "--ask", "which?"], on: h)
            let text = try require(model.lastRequest?.messages.first?.text)
            let start = try require(text.range(of: "<board>\n")), end = try require(text.range(of: "\n</board>"))
            return String(text[start.upperBound..<end.lowerBound])
        }
        expectEqual(try board(), "The person is looking at the top board. Nothing is selected.")
        desk.picked = many.map(\.id)
        let named = (101..<120).map { "an untitled chore, #\(uuid($0))" }.joined(separator: ", ")
        expectEqual(try board(), #"The person is looking at the top board. Selected: "Say \"hi\" \\ bye" (chore), "# + named + ", and 5 more.")
        desk.picked = []
        expect(h.enter(id(2)) && h.enter(id(12)))
        expectEqual(try board(), "The person is looking at the board inside Pantry › Untitled Pocket. Nothing is selected.")
        let titles = try require(model.lastRequest?.messages.first?.text)
        expect(titles.contains(#""Say \"hi\" \\ bye" chore"#), "a title as a query writes it")
    },
    test("a block with nothing to say is left out: no titles, no titles block") {
        let model = ScriptedLanguageModel(answers: ["chore"])
        let file = CanvasFile(root: CanvasDocument(shapes: [chore(id(1)), chore(id(2))]))
        let h = try askHarness(model, file: file)
        _ = try answered(["query", "--ask", "all the chores"], on: h)
        let text = try require(model.lastRequest?.messages.first?.text)
        let vocabulary = try require(h.editor.queries).vocabulary.text
        expectEqual(text, """
            <question>
            all the chores
            </question>

            <vocabulary>
            \(vocabulary)
            </vocabulary>

            <board>
            The person is looking at the top board. Nothing is selected.
            </board>
            """)
    },
    test("a second try: the first answer as the model's, then only the error, the query and its refusal") {
        let model = ScriptedLanguageModel(answers: ["  chore:nope  ", "chore:top-level"])
        let h = try askHarness(model)
        let json = try answered(["query", "--ask", "top chores"], on: h)
        expectEqual(model.requests.count, 2)
        let first = try require(model.requests.first), second = try require(model.requests.last)
        let refusal = try require(checked("chore:nope", on: h))
        let error = "<error>\nquery: chore:nope\nrefused: unknown_pseudo_class: " + ([refusal.message] + (refusal.hint.map { [$0] } ?? [])).joined(separator: " ")
            + "\n</error>"
        expectEqual(second.messages, first.messages + [.assistant("chore:nope"), .user(error)])
        expectEqual(second.system, first.system)
        expectEqual(second.maxTokens, first.maxTokens)
        expectEqual(AskRequest.refusal(of: "chore:nope", refusal),
                    "query: chore:nope\nrefused: unknown_pseudo_class: \(refusal.message)" + (refusal.hint.map { " " + $0 } ?? ""))

        expectEqual(json["query"], "chore:top-level")
        expectEqual(json["asked"], "top chores")
        expectEqual(rowIDs(json), [uuid(1)])
        expectEqual(json["warnings"], [["reason": "repaired", "message": "Claude's first query was refused (unknown_pseudo_class); this is its second."]])
    },
    test("a first answer of several lines, the last no query: a second try told to put it on one") {
        let model = ScriptedLanguageModel(answers: ["Here it is:\nIt's every chore.", "chore"])
        let h = try askHarness(model)
        let json = try answered(["query", "--ask", "chores"], on: h)
        let second = try require(model.lastRequest)
        expectEqual(Array(second.messages.dropFirst()), [.assistant("Here it is:\nIt's every chore."),
                                                              .user("<error>\nReply with the query alone, on one line.\n</error>")])
        expectEqual(json["count"], 4)
        expectEqual(json["warnings"]?.arrayValue?.first?["reason"], "repaired")
        expectEqual(json["warnings"]?.arrayValue?.first?["message"], "Claude's first answer wasn't a query on one line; this is its second.")
    },
    test("reasoning, then the query on its last line: that query, run at once, with no second try") {
        let model = ScriptedLanguageModel(answers: ["Chores are what's asked, on every board.\n\nchore"])
        let h = try askHarness(model)
        let json = try answered(["query", "--ask", "chores"], on: h)
        expectEqual(model.requests.count, 1)
        expectEqual(json["query"], "chore")
        expectEqual(json["count"], 4)
        expectEqual(json["warnings"], nil)
    },
    test("AskStyle holds the model's settings: Sonnet 5.5's ship, the model named, no temperature, room to think, low effort, the service's fallback") {
        expectEqual(AskStyle.shipped, AskStyle.sonnet, "the model the evaluations picked")
        expectEqual(AskStyle.haiku, AskStyle(model: nil, temperature: 0, maxTokens: 400, effort: nil, fallbacks: nil))
        expectEqual(AskStyle.sonnet, AskStyle(model: "claude-sonnet-5-5", temperature: nil, maxTokens: 2_048, effort: "low", fallbacks: .default))
        expectEqual(AskStyle.named("claude-sonnet-5-5"), .sonnet)
        expectEqual(AskStyle.named(nil), .haiku)
        expectEqual(AskStyle.named(""), .haiku)
        expectEqual(AskStyle.named("claude-haiku-4-5").model, "claude-haiku-4-5")
        expectEqual(AskStyle.named("claude-haiku-4-5").temperature, 0)
        expectEqual(AskStyle.deadline, .seconds(55))
        expectEqual(AskStyle.repairBefore, .seconds(40))
        expectEqual(AskStyle.titles, 200)
        expectEqual(AskStyle.selected, 20)

        // As shipped: every request says the model, since the editor's is Haiku 4.5 (the schema cards'), a second try too.
        let model = ScriptedLanguageModel(answers: ["chor", "chore"])
        let h = try askHarness(model)
        let json = try answered(["query", "--ask", "chores"], on: h)
        expectEqual(json["query"], "chore")
        expectEqual(model.requests.count, 2)
        for request in model.requests {
            expectEqual(request.model, "claude-sonnet-5-5")
            expectEqual(request.temperature, nil)
            expectEqual(request.maxTokens, 2_048)
            expectEqual(request.effort, "low")
            expectEqual(request.fallbacks, .default)
        }
        let haiku = ScriptedLanguageModel(answers: ["chore"])
        _ = try answered(["query", "--ask", "chores"], on: try askHarness(haiku, askStyle: .haiku))
        let request = try require(haiku.lastRequest)
        expectEqual(request.model, nil, "the editor's own")
        expectEqual(request.temperature, 0)
        expectEqual(request.effort, nil)
        expectEqual(request.fallbacks, nil)
    },
])
