import Automation
import Canvas
import CanvasRPC
import Foundation
import Queries

/// What `canvas decide` takes: a query, a question, and how many shapes to ask about at most.
struct DecideParams: SchemaDefined {
    static let properties = Properties<DecideParams>(title: "decide") {
        Property("query", \.query).keywords(["x-stdin": true, "x-value-name": "query"])
            .description("Which shapes to ask about, in the query language (the canvas skill's reference/query.md).")
        Property("question", \.question).maxLength(DecideParams.questionLength)
            .keywords(["x-value-name": "question", "x-timeout": .number(DecideParams.wait)])
            .description("A question in English that each shape answers yes or no.")
        Property("limit", \.limit).minimum(1).maximum(Double(DecideParams.most))
            .description("The most shapes asked about, the first the query finds.")
    }

    /// The longest question, in characters.
    static let questionLength = 2_000
    /// How long `canvas` waits for the answers, in seconds: a call a shape, a few at once.
    static let wait: Double = 120
    /// The most shapes one run asks about.
    static let most = 500

    var query = ""
    var question = ""
    var limit = 50

    /// The question, which must say something.
    func asked() throws(AutomationError) -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else {
            throw AutomationError(#"Say what to ask: a question, as "Does it say when it is due?"."#, reason: "invalid_params",
                                  hint: "`\(RPC.commandName) help decide` says what it takes.", invalidParams: true)
        }
        return question
    }
}
