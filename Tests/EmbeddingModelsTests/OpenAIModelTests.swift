import EmbeddingModels
import Foundation
import LanguageModels
import TestKit

private func bits(_ vectors: [[Float]]) -> [[UInt32]] { vectors.map { $0.map(\.bitPattern) } }

private let odd: [Float] = [0.1, -0.0, Float.leastNonzeroMagnitude, 3.4028235e38, -2.5e-7, .pi]

/// The answer to a request of any size: a vector for each text, its first number the text's length and its second its place in the
/// request.
private let echo: StubProtocol.Answer = .computed { received in
    let texts = inputs(of: received)
    return (200, embeddingReply(texts.enumerated().map { [Float($0.element.count), Float($0.offset)] }))
}

@MainActor let openAIRequestTests = Suite("OpenAI's request", [
    test("goes to OpenAI's embeddings API with the key as a bearer token, and JSON") {
        try withStubbedModel(answering: .http(status: 200, body: embeddingReply([[1, 2]]))) { model in
            _ = try outcome(of: model, ["a text"])
            expectEqual(StubProtocol.received.count, 1)
            let sent = try require(StubProtocol.received.first).request
            expectEqual(sent.url, URL(string: "https://api.openai.com/v1/embeddings"))
            expectEqual(sent.httpMethod, "POST")
            expectEqual(sent.value(forHTTPHeaderField: "authorization"), "Bearer \(testKey)")
            expectEqual(sent.value(forHTTPHeaderField: "content-type"), "application/json")
            expectEqual(sent.timeoutInterval, 60)
        }
    },
    test("a model with no session of its own asks over one that bounds each whole request, and not only the silence on it") {
        let model = OpenAIEmbeddingModel(timeout: 7)
        let session = model.boundedSession()
        defer { session.invalidateAndCancel() }
        expectEqual(session.configuration.timeoutIntervalForRequest, 7)
        expectEqual(session.configuration.timeoutIntervalForResource, 7, "the default is a week")
        expectEqual(OpenAIEmbeddingModel().boundedSession().configuration.timeoutIntervalForResource, 60)
    },
    test("its body, sorted keys: base64 for the numbers, the texts as they are, text-embedding-3-large, and no dimensions") {
        try withStubbedModel(answering: .http(status: 200, body: embeddingReply([[1], [2]]))) { model in
            _ = try outcome(of: model, ["first", "caf\u{E9} \"quoted\" a/b"])
            let body = String(decoding: try require(StubProtocol.received.first).body, as: UTF8.self)
            expectEqual(body, #"{"encoding_format":"base64","input":["first","café \"quoted\" a/b"],"model":"text-embedding-3-large"}"#)
            expect(!body.contains("dimensions"))
        }
    },
    test("with no key saved, nothing is sent: \"No OpenAI key\", which Settings answers") {
        try withTemporaryStore { keys in
            let model = OpenAIEmbeddingModel(keys: keys, session: StubProtocol.session(answering: .http(status: 200, body: embeddingReply([[1]]))))
            let error = try require(try outcome(of: model, ["a"]).failureValue)
            expectEqual(error.failure, .noKey)
            expectEqual(error.message, "No OpenAI key")
            expect(error.needsKey && !error.isTransient)
            expectEqual(StubProtocol.received.count, 0)
        }
    },
    test("the key is read at every call: one saved between two is used at once, one removed stops it") {
        try withTemporaryStore { keys in
            let model = OpenAIEmbeddingModel(keys: keys, session: StubProtocol.session(answering: .http(status: 200, body: embeddingReply([[1]]))))
            expectEqual(try require(try outcome(of: model, ["a"]).failureValue).failure, .noKey)
            try keys.write(testKey)
            expect(try outcome(of: model, ["a"]).successValue != nil)
            try keys.remove()
            expectEqual(try require(try outcome(of: model, ["a"]).failureValue).failure, .noKey)
            expectEqual(StubProtocol.received.count, 1)
        }
    },
    test("a batch past 256 is several requests, in order, and the vectors are joined in the order of the texts") {
        try withStubbedModel(answering: echo) { model in
            let texts = (0..<600).map { String(repeating: "x", count: $0 % 7 + 1) + "\($0)" }
            let vectors = try require(try outcome(of: model, texts).successValue)
            expectEqual(StubProtocol.received.map { inputs(of: $0).count }, [256, 256, 88])
            expectEqual(StubProtocol.received.flatMap(inputs(of:)), texts, "in order, once each")
            expectEqual(vectors.count, 600)
            expectEqual(vectors.map { $0[0] }, texts.map { Float($0.count) })
            expectEqual(vectors[300][1], Float(300 - 256), "its place in its own request")
        }
    },
    test("no texts send nothing") {
        try withStubbedModel(answering: echo) { model in
            expectEqual(try require(try outcome(of: model, []).successValue).count, 0)
            expectEqual(StubProtocol.received.count, 0)
        }
    },
    test("the app's model is text-embedding-3-large, 256 texts a request, with the key from Settings") {
        let model = OpenAIEmbeddingModel()
        expectEqual(model.model, "text-embedding-3-large")
        expectEqual(OpenAIEmbeddingModel.latest, "text-embedding-3-large")
        expectEqual(model.name, "openai/text-embedding-3-large")
        expectEqual(model.textsPerRequest, 256)
        expectEqual(model.keys, .standard)
        expectEqual(OpenAIKeyStore.standard.url.path, "\(NSHomeDirectory())/Library/Application Support/InfiniteCanvas/openai-api-key")
    },
])

@MainActor let openAIAnswerTests = Suite("OpenAI's answers", [
    test("each vector by its index, exactly as sent, even when the reply is out of order") {
        let vectors: [[Float]] = [odd, odd.reversed(), [1, 2, 3, 4, 5, 6]]
        let reply = embeddingReply([(index: 2, vector: vectors[2]), (index: 0, vector: vectors[0]), (index: 1, vector: vectors[1])])
        try withStubbedModel(answering: .http(status: 200, body: reply)) { model in
            expectEqual(bits(try require(try outcome(of: model, ["a", "b", "c"]).successValue)), bits(vectors))
        }
    },
    test("a reply that isn't one is an unusable answer: a missing index, a repeated one, a wrong count, ragged or empty vectors, numbers that aren't finite, not base64, not JSON") {
        let nan = Float.nan, infinity = Float.infinity
        let replies = [
            embeddingReply([(index: 0, vector: [1, 2]), (index: 2, vector: [1, 2])]),
            embeddingReply([(index: 0, vector: [1, 2]), (index: 0, vector: [1, 2])]),
            embeddingReply([(index: 0, vector: [1, 2])]),
            embeddingReply([(index: 0, vector: [1, 2]), (index: 1, vector: [1, 2]), (index: 2, vector: [1, 2])]),
            embeddingReply([(index: 0, vector: [1, 2]), (index: 1, vector: [1, 2, 3])]),
            embeddingReply([(index: 0, vector: []), (index: 1, vector: [])]),
            embeddingReply([(index: 0, vector: [1, nan]), (index: 1, vector: [1, 2])]),
            embeddingReply([(index: 0, vector: [1, 2]), (index: 1, vector: [infinity, 2])]),
            #"{"data":[{"index":0,"embedding":"not base64!"},{"index":1,"embedding":"AAAA"}]}"#,
            #"{"data":[{"index":0,"embedding":"AAA="},{"index":1,"embedding":"AAA="}]}"#,
            #"{"data":[{"index":-1,"embedding":"AAAAAA=="},{"index":1,"embedding":"AAAAAA=="}]}"#,
            #"{"data":[{"index":0,"embedding":[0.1,0.2]},{"index":1,"embedding":[0.1,0.2]}]}"#,
            #"{"object":"list"}"#,
            "not json",
        ]
        for body in replies {
            try withStubbedModel(answering: .http(status: 200, body: body)) { model in
                let error = try require(try outcome(of: model, ["a", "b"]).failureValue, body)
                expectEqual(error.message, "Unusable answer", body)
            }
        }
    },
    test("a vector asked of one text is answered whole, thousands of numbers") {
        let vector = (0..<3072).map { Float($0) / 3072 - 0.25 }
        try withStubbedModel(answering: .http(status: 200, body: embeddingReply([vector]))) { model in
            expectEqual(bits(try require(try outcome(of: model, ["a"]).successValue)), bits([vector]))
        }
    },
    test("one request failing fails the call, nothing partial") {
        let count = OSLockedCount()
        try withStubbedModel(answering: .computed { received in
            if count.next() == 2 { return (500, "{}") }
            return (200, embeddingReply(inputs(of: received).map { _ in [1, 2] }))
        }, textsPerRequest: 2) { model in
            let error = try require(try outcome(of: model, ["a", "b", "c", "d", "e"]).failureValue)
            expectEqual(error.message, "OpenAI error 500")
            expectEqual(StubProtocol.received.count, 2, "no request after the one that failed")
        }
    },
])

@MainActor let openAIErrorTests = Suite("OpenAI's errors", [
    test("each status, said as OpenAI's, and whether trying again may help") {
        let cases: [(Int, String, String, Bool, Bool)] = [
            (401, "{}", "OpenAI key rejected", false, true),
            (403, "{}", "OpenAI key rejected", false, true),
            (429, #"{"error":{"message":"Slow down.","code":"rate_limit_exceeded"}}"#, "Rate limited", true, false),
            (429, "{}", "Rate limited", true, false),
            (503, "{}", "OpenAI overloaded", true, false),
            (500, #"{"error":{"message":"Internal error. Sorry."}}"#, "OpenAI error 500", true, false),
            (400, #"{"error":{"message":"The input is too long. Shorten it.","type":"invalid_request_error"}}"#, "The input is too long", false, false),
            (422, #"{"error":{"message":"Bad key \#(testKey) given."}}"#, "Bad key … given", false, false),
            (404, "", "OpenAI error 404", false, false),
        ]
        for (status, body, message, transient, needsKey) in cases {
            try withStubbedModel(answering: .http(status: status, body: body)) { model in
                let error = try require(try outcome(of: model, ["a"]).failureValue)
                expectEqual(error.message, message, "\(status)")
                expectEqual(error.isTransient, transient, "\(status)")
                expectEqual(error.needsKey, needsKey, "\(status)")
                expectEqual(error.provider, "OpenAI")
                expect(!error.message.contains(testKey), "never the key")
            }
        }
    },
    test("insufficient_quota is the service's words, not a rate") {
        let body = #"{"error":{"message":"You exceeded your current quota, please check your plan and billing details. For more information, read the docs.","type":"insufficient_quota","code":"insufficient_quota"}}"#
        try withStubbedModel(answering: .http(status: 429, body: body)) { model in
            let error = try require(try outcome(of: model, ["a"]).failureValue)
            expectEqual(error.failure, .server(status: 429, message: "You exceeded your current quota, please check your plan and billing details"))
            expectEqual(error.message, "You exceeded your current quota, please check your plan and billing details")
            expect(!error.isTransient && !error.needsKey)
        }
    },
    test("the key is taken out of a refused message, whole and as anything that looks like a key's start") {
        let body = #"{"error":{"message":"No such model for \#(testKey) or \#(testKey.prefix(9)) or sk-proj-****."}}"#
        try withStubbedModel(answering: .http(status: 404, body: body)) { model in
            let error = try require(try outcome(of: model, ["a"]).failureValue)
            expectEqual(error.message, "No such model for … or … or …")
            guard case let .server(_, message) = error.failure else { return expect(false, "a server failure") }
            expect(!(message ?? "").contains(testKey))
            expect(!(message ?? "").contains("sk-"))
        }
    },
    test("a 400 whose message quotes a masked key gives a message without it") {
        let body = #"{"error":{"message":"Incorrect API key provided: sk-proj-****abcd. You can find your API key at the console.","type":"invalid_request_error"}}"#
        try withStubbedModel(answering: .http(status: 400, body: body)) { model in
            let error = try require(try outcome(of: model, ["a"]).failureValue)
            for text in [error.message, "\(error.failure)", error.errorDescription ?? ""] {
                expect(!text.contains("sk-"), text)
                expect(!text.contains("abcd"), text)
                expect(!text.contains("****"), text)
            }
        }
    },
    test("a 401 reads no body: only the status says what went wrong") {
        let body = #"{"error":{"message":"Incorrect API key provided: \#(testKey). Find yours at the console."}}"#
        try withStubbedModel(answering: .http(status: 401, body: body)) { model in
            let error = try require(try outcome(of: model, ["a"]).failureValue)
            expectEqual(error.failure, .unauthorized)
            expect(!"\(error)".contains("Incorrect") && !"\(error)".contains(testKey))
        }
    },
    test("the network: can't reach OpenAI, or timed out") {
        try withStubbedModel(answering: .failure(.notConnectedToInternet)) { model in
            let error = try require(try outcome(of: model, ["a"]).failureValue)
            expectEqual(error.message, "Can’t reach OpenAI")
            expect(error.isTransient)
        }
        try withStubbedModel(answering: .failure(.timedOut)) { model in
            expectEqual(try require(try outcome(of: model, ["a"]).failureValue).message, "Timed out")
        }
    },
    test("cancelling the asking task stops a call that hangs, cancelled") {
        try withStubbedModel(answering: .hang) { model in
            let result = try awaitResult { () async -> Result<[[Float]], EmbeddingModelError> in
                let task = Task { () async -> Result<[[Float]], EmbeddingModelError> in
                    do throws(EmbeddingModelError) { return .success(try await model.embed(["a"])) } catch { return .failure(error) }
                }
                try? await Task.sleep(for: .milliseconds(50))
                task.cancel()
                return await task.value
            }
            expectEqual(result.failureValue?.failure, .cancelled)
        }
    },
    test("a task cancelled before it asks sends nothing") {
        try withStubbedModel(answering: echo) { model in
            let result = try awaitResult { () async -> Result<[[Float]], EmbeddingModelError> in
                let task = Task { () async -> Result<[[Float]], EmbeddingModelError> in
                    while !Task.isCancelled { await Task.yield() }
                    do throws(EmbeddingModelError) { return .success(try await model.embed(["a"])) } catch { return .failure(error) }
                }
                task.cancel()
                return await task.value
            }
            expectEqual(result.failureValue?.failure, .cancelled)
            expectEqual(StubProtocol.received.count, 0)
        }
    },
])

/// A count a stub's answer takes, from any thread.
private final class OSLockedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
