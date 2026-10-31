import Canvas
import CanvasRPC
import Foundation
import LanguageModels

/// A decision model that asks a language model (Claude Haiku 5.5, by default) and reads its answers
/// in words: each question answered with its own yes or no words, word for word, or "unsure"; a yes
/// is 1, a no 0 and unsure 0.5. Words, not "yes" and "no": asked whether something fails, a model
/// answering "yes" was read as "it holds" (the prototype's first round, 2026-10-27). It proves the
/// seam isn't shaped around Jev, and answers where a person would rather use their Anthropic key.
public struct LanguageDecisionModel: DecisionModel {
    /// Claude Haiku 5.5.
    public static let haiku55 = "claude-haiku-5-5"
    /// What its errors call it.
    public static let provider = "Anthropic"

    /// The language model asked.
    public let model: any LanguageModel
    /// Which of its models answers, by id.
    public let modelID: String
    /// How much it spends on an answer, nil for its default: `medium`, as the prototype's boards
    /// were judged.
    public let effort: String?
    /// The most an answer may run to, its thinking included.
    public let maxTokens: Int

    public init(model: any LanguageModel, modelID: String = LanguageDecisionModel.haiku55, effort: String? = "medium",
                maxTokens: Int = 2048) {
        self.model = model
        self.modelID = modelID
        self.effort = effort
        self.maxTokens = maxTokens
    }

    public var name: String { modelID }
    public var cutoffs: DecisionCutoffs { .standard }

    /// The task, as the system prompt says it: knowing nothing of what's asked about.
    public static let system = """
        You answer questions about a state. The user message gives the state, as JSON, then the \
        questions, each with its two answers. Judge only from what you are given and plain common \
        knowledge; never assume what isn't there. Answer with one JSON object and nothing else.
        """

    /// The one user message: the state, the preface, then the questions numbered, each with its two
    /// answers, and the answer's form.
    public static func message(for request: DecisionRequest) -> String {
        var text = "<state>\n\(request.state.prettyText)\n</state>\n\n"
        if let preface = request.preface, !preface.isEmpty { text += preface + "\n\n" }
        text += "<questions>\n"
        for (index, question) in request.questions.enumerated() {
            text += "\(index + 1). \(question.asks)\n   Answer \"\(question.yes)\" or \"\(question.no)\".\n"
        }
        let form = request.questions.indices.map { "\"\($0 + 1)\": \"…\"" }.joined(separator: ", ")
        text += "</questions>\n\nAnswer {\(form)}: for each question, one of its two answers word for word, or \"unsure\"."
        return text
    }

    public func modelRequest(for request: DecisionRequest) -> ModelRequest {
        ModelRequest(system: Self.system, messages: [.user(Self.message(for: request))], maxTokens: maxTokens,
                     model: modelID, effort: effort)
    }

    public func decide(_ request: DecisionRequest) async throws(DecisionModelError) -> DecisionAnswers {
        let response: ModelResponse
        do throws(LanguageModelError) {
            response = try await model.respond(to: modelRequest(for: request))
        } catch {
            throw DecisionModelError(error, of: Self.provider)
        }
        guard let yes = Self.answers(response.text, questions: request.questions) else {
            throw DecisionModelError(.malformedResponse, provider: Self.provider)
        }
        return DecisionAnswers(model: modelID, yes: yes,
                               usage: DecisionUsage(inputTokens: response.inputTokens, outputTokens: response.outputTokens))
    }

    /// Each question's probability of yes from an answer's last JSON object: its yes words 1, its no
    /// words 0, "unsure" 0.5, compared without case, the space around them or a closing period; a
    /// question answered otherwise, or not at all, is left out. Nil when the text holds no object.
    static func answers(_ text: String, questions: [DecisionQuestion]) -> [String: Double]? {
        guard let object = lastObject(in: text) else { return nil }
        func folded(_ words: String) -> String {
            var words = words.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            while words.hasSuffix(".") { words.removeLast() }
            return words
        }
        var yes: [String: Double] = [:]
        for (index, question) in questions.enumerated() {
            guard let said = object[String(index + 1)]?.stringValue.map(folded) else { continue }
            if said == folded(question.yes) { yes[question.id] = 1 }
            else if said == folded(question.no) { yes[question.id] = 0 }
            else if said == "unsure" { yes[question.id] = 0.5 }
        }
        return yes
    }

    /// The last `{…}` in `text` that reads as a JSON object: an answer may say something before it
    /// or after it (a brace too), or fence it. Each closing brace from the last, with each opening one
    /// before it from the nearest.
    static func lastObject(in text: String) -> [String: JSONValue]? {
        var ends = text.endIndex
        while let end = text[..<ends].lastIndex(of: "}") {
            var start = end
            while let open = text[..<start].lastIndex(of: "{") {
                if let object = (try? JSON(text: String(text[open...end])))?.objectValue { return object }
                start = open
            }
            ends = end
        }
        return nil
    }
}
