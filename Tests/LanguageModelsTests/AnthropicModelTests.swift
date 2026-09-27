import Foundation
import LanguageModels
import TestKit

@MainActor let requestTests = Suite("The request", [
    test("goes to the Messages API with the key, the version and JSON") {
        try withStubbedModel(answering: .http(status: 200, body: reply("OK"))) { model in
            _ = try outcome(of: model)
            let sent = try require(StubProtocol.received.first).request
            expectEqual(StubProtocol.received.count, 1)
            expectEqual(sent.url, URL(string: "https://api.anthropic.com/v1/messages"))
            expectEqual(sent.httpMethod, "POST")
            expectEqual(sent.value(forHTTPHeaderField: "x-api-key"), testKey)
            expectEqual(sent.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
            expectEqual(sent.value(forHTTPHeaderField: "content-type"), "application/json")
            expectEqual(sent.timeoutInterval, 60 + 1024 / 100, "a minute, and a second a hundred tokens it may write")
        }
    },
    test("waits longer for an answer that may be long: it comes all at once") {
        let model = AnthropicModel(keys: AnthropicKeyStore(url: URL(fileURLWithPath: "/dev/null")))
        expectEqual(model.timeout(for: ModelRequest(messages: [.user("Hi")], maxTokens: 500)), 65)
        expectEqual(model.timeout(for: ModelRequest(messages: [.user("Hi")], maxTokens: 16_000)), 220)
        expectEqual(AnthropicModel(timeout: 10).timeout(for: ModelRequest(messages: [.user("Hi")], maxTokens: 1_000)), 20)
    },
    test("its body: Haiku, the system prompt, the conversation and every setting, in the API's names") {
        try withStubbedModel(answering: .http(status: 200, body: reply("OK"))) { model in
            let request = ModelRequest(system: "Be brief.", messages: [.user("Name a pet."), .assistant("A cat."), .user("Another.")],
                                       maxTokens: 300, temperature: 0.2, stopSequences: ["\n\n"])
            _ = try outcome(of: model, request)
            let body = try require(StubProtocol.received.first).body
            expectEqual(String(decoding: body, as: UTF8.self), #"""
            {"max_tokens":300,"messages":[{"content":"Name a pet.","role":"user"},{"content":"A cat.","role":"assistant"},{"content":"Another.","role":"user"}],"model":"claude-haiku-4-5","stop_sequences":["\n\n"],"system":"Be brief.","temperature":0.2}
            """#)
        }
    },
    test("leaves out what isn't set: no system prompt, temperature or stop sequences") {
        try withStubbedModel(answering: .http(status: 200, body: reply("OK"))) { model in
            _ = try outcome(of: model, ModelRequest(system: "", messages: [.user("Hi")], maxTokens: 5))
            let body = try require(StubProtocol.received.first).body
            expectEqual(String(decoding: body, as: UTF8.self), #"{"max_tokens":5,"messages":[{"content":"Hi","role":"user"}],"model":"claude-haiku-4-5"}"#)
        }
    },
    test("reads the key at every call: one saved after the model was made is the one sent") {
        try withTemporaryStore { keys in
            let model = AnthropicModel(keys: keys, session: StubProtocol.session(answering: .http(status: 200, body: reply("OK"))))
            expectEqual(try outcome(of: model), .failure(.noKey))
            try keys.write("sk-ant-later")
            expectEqual(try outcome(of: model), .success(ModelResponse(text: "OK", inputTokens: 12, outputTokens: 3)))
            expectEqual(StubProtocol.received.last?.request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-later")
        }
    },
    test("without a key, nothing is sent") {
        try withTemporaryStore { keys in
            let model = AnthropicModel(keys: keys, session: StubProtocol.session(answering: .http(status: 200, body: reply("OK"))))
            expectEqual(try outcome(of: model), .failure(.noKey))
            expect(StubProtocol.received.isEmpty)
        }
    },
])

@MainActor let responseTests = Suite("The response", [
    test("its text, stop reason and token counts") {
        try withStubbedModel(answering: .http(status: 200, body: reply("A cat named Tom.", stopReason: "max_tokens"))) { model in
            expectEqual(try outcome(of: model), .success(ModelResponse(text: "A cat named Tom.", stopReason: .maxTokens, inputTokens: 12, outputTokens: 3)))
        }
    },
    test("every text block, joined; other blocks left out") {
        let body = #"""
        {"content":[{"type":"text","text":"{\"a\":"},{"type":"thinking","thinking":""},{"type":"text","text":" 1}"}],
         "stop_reason":"end_turn","usage":{"input_tokens":1,"output_tokens":2}}
        """#
        try withStubbedModel(answering: .http(status: 200, body: body)) { model in
            expectEqual(try outcome(of: model).map(\.text), .success(#"{"a": 1}"#))
        }
    },
    test("a stop reason the app doesn't know is kept as it came") {
        try withStubbedModel(answering: .http(status: 200, body: reply("", stopReason: "refusal"))) { model in
            expectEqual(try outcome(of: model).map(\.stopReason), .success(.refusal))
        }
        try withStubbedModel(answering: .http(status: 200, body: reply("", stopReason: "something_new"))) { model in
            expectEqual(try outcome(of: model).map(\.stopReason), .success(StopReason(rawValue: "something_new")))
        }
    },
    test("an answer that isn't a message is a malformed response") {
        for body in ["", "not json", #"{"content":"text"}"#, #"{"content":[]}"#] {
            try withStubbedModel(answering: .http(status: 200, body: body)) { model in
                expectEqual(try outcome(of: model), .failure(.malformedResponse), body)
            }
        }
    },
])

@MainActor let errorTests = Suite("Errors", [
    test("each status as its error: 401 unauthorized, 429 rate limited, 529 overloaded, others with the service's message") {
        let cases: [(Int, String, LanguageModelError)] = [
            (401, errorBody("authentication_error", "invalid x-api-key"), .unauthorized),
            (429, errorBody("rate_limit_error", "Number of requests has exceeded your rate limit"), .rateLimited),
            (529, errorBody("overloaded_error", "Overloaded"), .overloaded),
            (500, errorBody("api_error", "Internal server error"), .server(status: 500, message: "Internal server error")),
            (400, errorBody("invalid_request_error", "max_tokens: must be positive"), .server(status: 400, message: "max_tokens: must be positive")),
            (403, errorBody("permission_error", "Not allowed"), .server(status: 403, message: "Not allowed")),
            (502, "<html>Bad gateway</html>", .server(status: 502, message: "")),
            // Overloaded, whatever the status says.
            (503, errorBody("overloaded_error", "Overloaded"), .overloaded),
        ]
        for (status, body, expected) in cases {
            try withStubbedModel(answering: .http(status: status, body: body)) { model in
                expectEqual(try outcome(of: model), .failure(expected), "\(status)")
            }
        }
    },
    test("no network is a network error, with the system's words") {
        try withStubbedModel(answering: .failure(.notConnectedToInternet)) { model in
            guard case let .failure(.network(description)) = try outcome(of: model) else { return expect(false, "not a network error") }
            expect(!description.isEmpty)
        }
        try withStubbedModel(answering: .failure(.timedOut)) { model in
            expectEqual(try outcome(of: model), .failure(.timedOut), "reached, but no answer in time")
        }
    },
    test("cancelling the task asking cancels the request, and throws cancelled") {
        try withStubbedModel(answering: .hang) { model in
            var result: Result<ModelResponse, LanguageModelError>?
            let task = Task { @MainActor in
                do throws(LanguageModelError) {
                    result = .success(try await model.respond(to: ModelRequest(messages: [.user("Hi")])))
                } catch {
                    result = .failure(error)
                }
            }
            spinRunLoop(until: { StubProtocol.received.count == 1 })
            expectEqual(result, nil, "it waits for an answer")
            task.cancel()
            spinRunLoop(until: { result != nil })
            expectEqual(result, .failure(.cancelled))
        }
    },
    test("a task cancelled before it asks sends nothing") {
        try withStubbedModel(answering: .http(status: 200, body: reply("OK"))) { model in
            let result = try awaitResult { () async -> Result<ModelResponse, LanguageModelError> in
                withUnsafeCurrentTask { $0?.cancel() }
                do throws(LanguageModelError) {
                    return .success(try await model.respond(to: ModelRequest(messages: [.user("Hi")])))
                } catch {
                    return .failure(error)
                }
            }
            expectEqual(result, .failure(.cancelled))
            expect(StubProtocol.received.isEmpty)
        }
    },
    test("every error has a short message for a person, and says which may pass") {
        let all: [LanguageModelError] = [.noKey, .unauthorized, .rateLimited, .overloaded, .server(status: 500, message: "Boom"),
                                         .server(status: 400, message: ""), .network("The Internet connection appears to be offline."),
                                         .timedOut, .malformedResponse, .cancelled]
        for error in all {
            expect(!error.message.isEmpty && error.message.count < 120, "\(error)")
            expectEqual(error.localizedDescription, error.message)
        }
        expectEqual(LanguageModelError.noKey.message, "Add your Anthropic API key in Settings…")
        expectEqual(LanguageModelError.server(status: 500, message: "Boom").message, "Anthropic answered with an error (500): Boom")
        expectEqual(all.filter(\.isTransient), [.rateLimited, .overloaded, .server(status: 500, message: "Boom"),
                                                .network("The Internet connection appears to be offline."), .timedOut])
    },
])
