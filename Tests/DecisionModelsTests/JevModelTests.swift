import CanvasRPC
import DecisionModels
import Foundation
import TestKit

@MainActor let jevRequestTests = Suite("Jev's request", [
    test("goes to TypeSafe's API with the key as a bearer token, and JSON") {
        try withStubbedJev(answering: .http(status: 200, body: jevReply(["all": 0.9, "r0": 0.8]))) { jev in
            _ = try outcome(of: jev)
            expectEqual(StubProtocol.received.count, 1)
            let sent = try require(StubProtocol.received.first).request
            expectEqual(sent.url, URL(string: "https://api.typesafe.ai/v1/systemone"))
            expectEqual(sent.httpMethod, "POST")
            expectEqual(sent.value(forHTTPHeaderField: "authorization"), "Bearer \(testKey)")
            expectEqual(sent.value(forHTTPHeaderField: "content-type"), "application/json")
            expectEqual(sent.timeoutInterval, 30)
        }
    },
    test("its body: the state as it is, the latest Jev, and each question a noul whose instructions are the preface and what it asks") {
        try withStubbedJev(answering: .http(status: 200, body: jevReply(["all": 0.9, "r0": 0.8]))) { jev in
            _ = try outcome(of: jev)
            let body = try JSON(data: try require(StubProtocol.received.first).body)
            expectEqual(body["model"], "jev-latest")
            expectEqual(body["state"], carRequest.state)
            expectEqual(body["questions"]?["all"], ["type": "noul", "instructions": "These rules come from the car's types.\nRead together, should this car be flagged?",
                                                    "criteria": ["true": "Flag it", "false": "Don't flag it"]])
            expectEqual(body["questions"]?["r0"]?["criteria"], ["true": "Yes", "false": "No"], "a yes and a no, unless the question says")
            expectEqual(body["questions"]?.objectValue?.count, 2)
        }
    },
    test("with no preface, a question's instructions are what it asks") {
        try withStubbedJev(answering: .http(status: 200, body: jevReply(["q": 0.5]))) { jev in
            _ = try outcome(of: jev, DecisionRequest(state: [:], questions: [DecisionQuestion(id: "q", asks: "Is it?")]))
            let body = try JSON(data: try require(StubProtocol.received.first).body)
            expectEqual(body["questions"]?["q"]?["instructions"], "Is it?")
        }
    },
    test("with no key saved, nothing is sent: \"No TypeSafe key\", which Settings answers") {
        try withTemporaryStore { keys in
            let jev = JevModel(keys: keys, session: StubProtocol.session(answering: .http(status: 200, body: jevReply([:]))))
            let error = try require(try outcome(of: jev).failureValue)
            expectEqual(error.failure, .noKey)
            expectEqual(error.message, "No TypeSafe key")
            expect(error.needsKey && !error.isTransient)
            expectEqual(StubProtocol.received.count, 0)
        }
    },
    test("the app's Jev is the latest, with the app's key") {
        let jev = JevModel()
        expectEqual(jev.model, "jev-latest")
        expectEqual(jev.keys, .standard)
        expectEqual(TypeSafeKeyStore.standard.url.path, "\(NSHomeDirectory())/Library/Application Support/InfiniteCanvas/typesafe-api-key")
    },
])

@MainActor let jevAnswerTests = Suite("Jev's answers", [
    test("each question's noul, by its id, with the version that answered and what it spent") {
        try withStubbedJev(answering: .http(status: 200, body: jevReply(["all": 0.74, "r0": 0.21]))) { jev in
            let answers = try require(try outcome(of: jev).successValue)
            expectEqual(answers.yes, ["all": 0.74, "r0": 0.21])
            expectEqual(answers.model, "jev-1.14.0")
            expectEqual(answers.usage, DecisionUsage(inputTokens: 3603, outputTokens: 38))
        }
    },
    test("a question left unanswered is left out; one asked of none, ignored") {
        try withStubbedJev(answering: .http(status: 200, body: jevReply(["all": 0.1, "other": 0.9]))) { jev in
            let answers = try require(try outcome(of: jev).successValue)
            expectEqual(answers.yes, ["all": 0.1])
        }
    },
    test("a reply with no answers, or a noul that isn't a probability, is no answer") {
        for body in [#"{"model":"jev-1.14.0"}"#, jevReply(["all": 1.5]), #"{"answers":{"all":{"type":"noul","noul":"high"}}}"#, "not json"] {
            try withStubbedJev(answering: .http(status: 200, body: body)) { jev in
                let error = try require(try outcome(of: jev).failureValue)
                expectEqual(error.message, "Unusable answer", body)
            }
        }
    },
])

@MainActor let jevErrorTests = Suite("Jev's errors", [
    test("each status, said as TypeSafe's, and whether trying again may help") {
        let cases: [(Int, String, String, Bool, Bool)] = [
            (401, "{}", "TypeSafe key rejected", false, true),
            (403, "{}", "TypeSafe key rejected", false, true),
            (429, "{}", "Rate limited", true, false),
            (529, "{}", "TypeSafe overloaded", true, false),
            (500, #"{"detail":"Internal error. Sorry."}"#, "TypeSafe error 500", true, false),
            (400, #"{"detail":"Question r0 has no criteria. See the docs."}"#, "Question r0 has no criteria", false, false),
            (422, #"{"error":{"message":"Bad key \#(testKey) given."}}"#, "Bad key … given", false, false),
            (404, "", "TypeSafe error 404", false, false),
        ]
        for (status, body, message, transient, needsKey) in cases {
            try withStubbedJev(answering: .http(status: status, body: body)) { jev in
                let error = try require(try outcome(of: jev).failureValue)
                expectEqual(error.message, message, "\(status)")
                expectEqual(error.isTransient, transient, "\(status)")
                expectEqual(error.needsKey, needsKey, "\(status)")
                expectEqual(error.provider, "TypeSafe")
                expect(!error.message.contains(testKey), "never the key")
            }
        }
    },
    test("the network: can't reach TypeSafe, or timed out") {
        try withStubbedJev(answering: .failure(.notConnectedToInternet)) { jev in
            let error = try require(try outcome(of: jev).failureValue)
            expectEqual(error.message, "Can’t reach TypeSafe")
            expect(error.isTransient)
        }
        try withStubbedJev(answering: .failure(.timedOut)) { jev in
            expectEqual(try require(try outcome(of: jev).failureValue).message, "Timed out")
        }
    },
    test("cancelling the asking task stops a call that hangs, cancelled") {
        try withStubbedJev(answering: .hang) { jev in
            let result = try awaitResult { () async -> Result<DecisionAnswers, DecisionModelError> in
                let task = Task { () async -> Result<DecisionAnswers, DecisionModelError> in
                    do throws(DecisionModelError) { return .success(try await jev.decide(carRequest)) } catch { return .failure(error) }
                }
                try? await Task.sleep(for: .milliseconds(50))
                task.cancel()
                return await task.value
            }
            expectEqual(result.failureValue?.failure, .cancelled)
        }
    },
])

extension Result {
    var successValue: Success? { if case .success(let value) = self { value } else { nil } }
    var failureValue: Failure? { if case .failure(let error) = self { error } else { nil } }
}
