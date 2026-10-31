import CanvasRPC
import DecisionModels
import LanguageModels
import TestKit

@MainActor let languageDecisionTests = Suite("A language model's decisions", [
    test("asks Haiku 5.5 at medium effort, once, with the state, the preface said once, and each question with its two answers") {
        let language = ScriptedLanguageModel(answers: [#"{"1": "Flag it", "2": "No"}"#])
        _ = try outcome(of: LanguageDecisionModel(model: language))
        expectEqual(language.requests.count, 1)
        let request = try require(language.lastRequest)
        expectEqual(request.model, "claude-haiku-5-5")
        expectEqual(request.effort, "medium")
        expectEqual(request.temperature, nil)
        expectEqual(request.maxTokens, 2048)
        expectEqual(request.system, LanguageDecisionModel.system)
        expectEqual(request.messages, [.user(LanguageDecisionModel.message(for: carRequest))])
        let message = LanguageDecisionModel.message(for: carRequest)
        expect(message.hasPrefix("<state>\n\(carRequest.state.prettyText)\n</state>\n\n"), message)
        expect(message.contains("These rules come from the car's types.\n\n<questions>\n"), message)
        expect(message.contains(#"1. Read together, should this car be flagged?"# + "\n" + #"   Answer "Flag it" or "Don't flag it"."#), message)
        expect(message.contains(#"2. Does rule 1 flag it?"# + "\n" + #"   Answer "Yes" or "No"."#), message)
        expect(message.hasSuffix(#"Answer {"1": "…", "2": "…"}: for each question, one of its two answers word for word, or "unsure"."#), message)
    },
    test("reads each answer in its own words: a yes 1, a no 0, unsure 0.5, whatever the case or a closing period") {
        let language = ScriptedLanguageModel(answers: [#"{"1": "flag it.", "2": "Unsure"}"#, #"{"1": " Don't flag it ", "2": "YES"}"#])
        let model = LanguageDecisionModel(model: language)
        let first = try require(try outcome(of: model).successValue)
        expectEqual(first.yes, ["all": 1, "r0": 0.5])
        expectEqual(first.model, "claude-haiku-5-5")
        expectEqual(try require(try outcome(of: model).successValue).yes, ["all": 0, "r0": 1])
    },
    test("an answer in other words is left out: asked whether it fails, a bare yes isn't read as either") {
        let language = ScriptedLanguageModel(answers: [#"{"1": "yes", "2": "maybe"}"#])
        expectEqual(try require(try outcome(of: LanguageDecisionModel(model: language)).successValue).yes, [:])
    },
    test("finds the object after words or in a fence, and the last one written") {
        let answers = ["Thinking it over.\n```json\n{\"1\": \"Flag it\", \"2\": \"No\"}\n```",
                       #"{"1": "Don't flag it"} on reflection {"1": "Flag it", "2": {"nested": true}}"#,
                       #"{"1": "Flag it", "2": "Yes"} (the second as {a} read it)"#]
        let language = ScriptedLanguageModel(answers: answers)
        let model = LanguageDecisionModel(model: language)
        expectEqual(try require(try outcome(of: model).successValue).yes, ["all": 1, "r0": 0])
        expectEqual(try require(try outcome(of: model).successValue).yes, ["all": 1])
        expectEqual(try require(try outcome(of: model).successValue).yes, ["all": 1, "r0": 1], "a brace in words after the object")
    },
    test("an answer with no object is unusable; the language model's failures are said as Anthropic's") {
        let language = ScriptedLanguageModel(answers: ["I can't tell."])
        language.queue(.notSignedIn)
        language.queue(.network("offline"))
        language.queue(.unauthorized)
        let model = LanguageDecisionModel(model: language)
        expectEqual(try require(try outcome(of: model).failureValue).message, "Unusable answer")
        let noKey = try require(try outcome(of: model).failureValue)
        expectEqual(noKey.message, "Not signed in")
        expect(noKey.needsKey)
        expectEqual(try require(try outcome(of: model).failureValue).message, "Can’t reach Anthropic")
        expectEqual(try require(try outcome(of: model).failureValue).message, "Anthropic key rejected")
    },
    test("what it spent is the language model's") {
        let language = ScriptedLanguageModel()
        language.queue(ModelResponse(text: #"{"1": "Flag it", "2": "Yes"}"#, inputTokens: 4400, outputTokens: 120))
        expectEqual(try require(try outcome(of: LanguageDecisionModel(model: language)).successValue).usage,
                    DecisionUsage(inputTokens: 4400, outputTokens: 120))
    },
])
