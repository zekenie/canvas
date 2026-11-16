import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import Queries
import QueryLanguage
import QueryTranslation
import TestKit
import Topology

// `translate` for words that say what a container accepts (`TranslationContext.accepting(holder:)`): a stored query,
// unbound, whose request gains one more system line after the rule line, the plugin's `accepts` with `{holder}` filled
// in. Fixtures only (translateHarness: captioned chores, a scripted model).

let acceptsLine = "The words name which shapes {holder} accepts."

@MainActor let acceptsTests = Suite("Translating what a container accepts", [
    test("the request is the stored one with the accepts line after the rule line, the holder filled in") {
        let model = ScriptedLanguageModel(answers: ["chore"])
        let h = try translateHarness(model, accepts: acceptsLine)
        let query = try require(try? translated("only chores", on: h, about: .accepting(holder: "Backlog")).get())
        expectEqual(query.query, "chore")
        expect(!query.repaired)
        let sent = try require(model.requests.first)
        expectEqual(sent.system, systemPrompt + "\n" + referenceRule + "\nThe words name which shapes Backlog accepts.")
        let text = message(sent)
        expect(text.hasPrefix("<question>\nonly chores\n</question>"), "the words are the question")
        expect(!text.contains("Selected"), "no selection in <board>: \(text)")
        expect(text.contains("<board>\nThe person is looking at the top board.\n</board>"))
        expect(!text.contains(":picked"), "the stored vocabulary: no word that reads the editor")
        expect(!text.contains(":scope"), "and none that only a bound query has")
        expectEqual(h.scheduler.pendingCount, 0)
    },

    test("another holder's name is filled as given, and a stored request has no accepts line") {
        let model = ScriptedLanguageModel(answers: ["chore", "chore"])
        let h = try translateHarness(model, accepts: acceptsLine)
        _ = try translated("only chores", on: h, about: .accepting(holder: "each Sprint"))
        _ = try translated("chores", on: h, about: .stored())
        expect(model.requests.first?.system?.hasSuffix("which shapes each Sprint accepts.") == true)
        expectEqual(model.requests.last?.system, systemPrompt + "\n" + referenceRule, "as a reference's")
    },

    test("with no line given nothing is added") {
        let model = ScriptedLanguageModel(answers: ["chore"])
        let h = try translateHarness(model)
        _ = try translated("only chores", on: h, about: .accepting(holder: "Backlog"))
        expectEqual(model.requests.first?.system, systemPrompt + "\n" + referenceRule)
    },

    test("the answer is checked stored and unbound: a word that reads the editor and :scope are refused, and repaired once") {
        for refused in ["chore:picked", "chore:scope"] {
            let model = ScriptedLanguageModel(answers: [refused, "chore"])
            let h = try translateHarness(model, accepts: acceptsLine)
            let query = try require(try? translated("only chores", on: h, about: .accepting(holder: "Backlog")).get(), refused)
            expectEqual(query.query, "chore")
            expect(query.repaired, refused)
            expectEqual(model.requests.count, 2)
            let error = try require(model.requests.last?.messages.last?.text)
            expect(error.contains(refused), "the second try is told the refusal of \(refused): \(error)")
        }
        let twice = ScriptedLanguageModel(answers: [":picked", ":picked"])
        let h = try translateHarness(twice, accepts: acceptsLine)
        guard case .failure(.unusable(_, let last, let refusal?)) = try translated("only chores", on: h, about: .accepting(holder: "Backlog")) else {
            return expect(false, "refused twice")
        }
        expectEqual(last, ":picked")
        expectEqual(refusal.message, QueryError.cantBeUsed(":picked"))
    },

    test("a negative phrase's :not comes back canonical, and a wrong title is repaired") {
        let model = ScriptedLanguageModel(answers: [#":not("Pantri")"#, #":not("Pantry")"#])
        let h = try translateHarness(model, accepts: acceptsLine)
        let query = try require(try? translated("nothing from the pantry", on: h, about: .accepting(holder: "Backlog")).get())
        expectEqual(query.query, try require(h.editor.queries).check(#":not("Pantry")"#).canonical)
        expect(query.repaired)
    },

    test("the model's refusals are as a stored query's: unanswerable, and no model") {
        let model = ScriptedLanguageModel(answers: ["UNANSWERABLE: where shapes sit"])
        let h = try translateHarness(model, accepts: acceptsLine)
        guard case .failure(let error) = try translated("only the ones at the left", on: h, about: .accepting(holder: "Backlog")) else { return expect(false, "answered") }
        expectEqual(error, .unanswerable("where shapes sit"))
        let none = try translateHarness(nil, accepts: acceptsLine)
        guard case .failure(let noModel) = try translated("only chores", on: none, about: .accepting(holder: "Backlog")) else { return expect(false, "answered") }
        expectEqual(noModel, .noModel)
    },

    test("the context says it is stored, who holds it, and is not bound") {
        let context = TranslationContext.accepting(holder: "Backlog")
        expect(context.isStored)
        expectEqual(context.holder, "Backlog")
        expect(context.binding == nil)
        expect(TranslationContext.stored().holder == nil && TranslationContext.person.holder == nil)
    },
])
