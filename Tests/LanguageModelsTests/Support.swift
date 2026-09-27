import Foundation
import LanguageModels
import os
import TestKit

/// The network, stubbed: a session whose every request goes to `StubProtocol`, which keeps it and
/// answers what the test said to (a status and a body, a transport error, or nothing, until the
/// request is cancelled). Nothing leaves the machine.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    enum Answer: Sendable {
        case http(status: Int, body: String)
        case failure(URLError.Code)
        /// Never answers: the request waits until it's cancelled.
        case hang
    }

    /// A request as it arrived, its body read out of its stream.
    struct Received: Sendable {
        let request: URLRequest
        let body: Data
    }

    private struct State {
        var answer: Answer = .failure(.notConnectedToInternet)
        var received: [Received] = []
    }

    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// A session that reaches only this stub, answering `answer` from now on.
    static func session(answering answer: Answer) -> URLSession {
        state.withLock { $0 = State(answer: answer) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    static var received: [Received] { state.withLock { $0.received } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.readAll) ?? Data()
        let answer = Self.state.withLock { state in
            state.received.append(Received(request: request, body: body))
            return state.answer
        }
        switch answer {
        case let .http(status, text):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["content-type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(text.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A fake key: what the tests save, and expect in the header.
let testKey = "sk-ant-test-0123456789"

/// A key store in a new temporary directory, which `body` may fill; removed after.
@MainActor
func withTemporaryStore(_ body: (AnthropicKeyStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "LanguageModelsTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(AnthropicKeyStore(url: directory.appending(path: "InfiniteCanvas/anthropic-api-key", directoryHint: .notDirectory)))
}

/// Claude, with `testKey` saved in a temporary store, over a session that reaches only the stub.
@MainActor
func withStubbedModel(answering answer: StubProtocol.Answer, _ body: (AnthropicModel) throws -> Void) throws {
    try withTemporaryStore { keys in
        try keys.write(testKey)
        try body(AnthropicModel(keys: keys, session: StubProtocol.session(answering: answer)))
    }
}

/// What `model` answers `request`, or the error it throws.
@MainActor
func outcome(of model: any LanguageModel, _ request: ModelRequest = ModelRequest(messages: [.user("Hi")])) throws -> Result<ModelResponse, LanguageModelError> {
    try awaitResult {
        do throws(LanguageModelError) {
            return .success(try await model.respond(to: request))
        } catch {
            return .failure(error)
        }
    }
}

/// A successful reply from the Messages API.
func reply(_ text: String, stopReason: String = "end_turn") -> String {
    """
    {"id":"msg_01","type":"message","role":"assistant","model":"claude-haiku-4-5",
     "content":[{"type":"text","text":\(json(text))}],
     "stop_reason":"\(stopReason)","stop_sequence":null,"usage":{"input_tokens":12,"output_tokens":3}}
    """
}

func errorBody(_ type: String, _ message: String) -> String {
    #"{"type":"error","error":{"type":"\#(type)","message":\#(json(message))},"request_id":"req_01"}"#
}

private func json(_ string: String) -> String {
    String(decoding: try! JSONEncoder().encode(string), as: UTF8.self)
}
